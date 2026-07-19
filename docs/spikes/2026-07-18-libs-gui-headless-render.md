# Spike: libs-gui headless render (Phase 0a)

Gating question: can GNUstep render offscreen and capture drawing operations
in a display-less (CI) environment? This document records the verbatim marker
output of throwaway probes run under three environments (has-display,
display-unset, Xvfb). Negative results are recorded as-is.

## Environment

Captured 2026-07-18 on the WSL Ubuntu box.

- GNUstep base: `libgnustep-base.so.1.31.1` (1.31)
- GNUstep gui: `libgnustep-gui.so.0.32.0` (0.32)
- Backend bundle: `libgnustep-back-032.bundle`. The default `.bundle` binary is
  byte-identical (sha1 `50bfd2f6…`) to the `.cairo` variant, so the active
  backend is **cairo**. Also present but not default: `.xlib` (sha1 `1d3845bc…`)
  and `.art` (sha1 `5a09b497…`).
- Default back bundle links: `libcairo.so.2`, `libwayland-client/egl/cursor`,
  `libX11.so.6`, `libxcb*`. So it can drive either Wayland or X11.
- Runtime: libobjc2 `libobjc.so.4.6`, `-fobjc-runtime=gnustep-2.2`.
- Compiler: Ubuntu clang 18.1.3.
- Display: `DISPLAY=:0` and `WAYLAND_DISPLAY=wayland-0` are always present
  (WSLg). Display-less is simulated with `env -u DISPLAY -u WAYLAND_DISPLAY`.
  This is an approximation; a truly display-less GitHub Actions ubuntu job is
  the authoritative headless gate (optional confirmation, Task 6).
- Xvfb: present at `/usr/bin/Xvfb` (started as `:99`, `1024x768x24`).
- gui link flags (`gnustep-config --gui-libs`):
  `-pthread -fexceptions -rdynamic -fobjc-runtime=gnustep-2.2 -fblocks -L…/Libraries -L/usr/local/lib -lgnustep-gui -lgnustep-base -lpthread -lobjc -lm`

Compile recipe used for every probe (LD path before `-lobjc` so it resolves to
libobjc2, not gcc's shadow):

```
. /usr/local/share/GNUstep/Makefiles/GNUstep.sh
clang <probe>.m -o <probe> -L/usr/local/lib $(gnustep-config --objc-flags) $(gnustep-config --gui-libs) -lobjc
```

Probes run with `export LD_LIBRARY_PATH=/usr/local/lib`.

## Probe A — offscreen bitmap render

Source: `~/gnustep-reaudit/.spike-headless-gui/probeA_bitmap.m`. Path:
`sharedApplication` + `NSImage lockFocus` + `NSRectFill` +
`initWithFocusedViewRect:` + PNG representation.

Compiled: **YES**, exit 0, no warnings/errors. Binary 53640 bytes.

Run command:
```
cd ~/gnustep-reaudit/.spike-headless-gui; export LD_LIBRARY_PATH=/usr/local/lib
# has-display / display-unset:
./probeA
env -u DISPLAY -u WAYLAND_DISPLAY ./probeA
# xvfb:
Xvfb :99 -screen 0 1024x768x24 >/dev/null 2>&1 & sleep 1; DISPLAY=:99 ./probeA
```

Verbatim marker output:

| Environment | Marker |
|---|---|
| has-display (`DISPLAY=:0`, wayland) | `BITMAP_OK bytes=91` (rc=0) |
| display-unset (`env -u DISPLAY -u WAYLAND_DISPLAY`) | `BITMAP_OK bytes=91` (rc=0) |
| Xvfb (`DISPLAY=:99`) | `BITMAP_OK bytes=91` (rc=0) |

Output file `~/probeA.png` validated: `PNG image data, 20 x 20, 8-bit/color
RGBA, non-interlaced` (91 bytes; solid-red fill compresses to a tiny PNG).

**Finding: the offscreen bitmap path works display-less.** This is contrary to
the plan's hypothesised "likely-informative" outcome (that the bitmap path
would FAIL display-unset because the backend needs an X/Wayland connection at
init). With the cairo backend, `NSImage lockFocus` renders into an in-memory
cairo image surface and requires no display server. So Tier C's bitmap lane is
headless-capable, not Xvfb-only. (Note: pixel checksums are not used for text
per the plan's determinism rule; here the content is a solid fill.)

## Probe B — draw-op stream via `dataWithEPSInsideRect:`

Source: `~/gnustep-reaudit/.spike-headless-gui/probeB_eps.m`. A `Box : NSView`
with a red-fill `drawRect:`; `main` calls `[v dataWithEPSInsideRect:[v bounds]]`
and writes the returned NSData to a file, printing `EPS_OK len=…`.

Compiled: **YES**, exit 0, no warnings/errors. Binary 53288 bytes. The selector
`dataWithEPSInsideRect:` **exists** in gui 0.32 (declared in `NSView.h`,
implemented `NSView.m:4023`).

Run command (display-unset, two runs for stability):
```
cd ~/gnustep-reaudit/.spike-headless-gui; export LD_LIBRARY_PATH=/usr/local/lib
env -u DISPLAY -u WAYLAND_DISPLAY ./probeB ~/probeB1.eps
env -u DISPLAY -u WAYLAND_DISPLAY ./probeB ~/probeB2.eps
```

Verbatim result — **NO marker was ever printed in any environment.** The call
`dataWithEPSInsideRect:` does not return control to our code. Observed:

| Environment | Behaviour |
|---|---|
| display-unset (`env -u DISPLAY -u WAYLAND_DISPLAY`) | **HANGS.** Prints `Creating a default printer since no printer has been set in the user defaults (under the GSLPRPrinters key).` then spins at **100% CPU indefinitely**. Process state `R+`, CPU TIME `02:46` at ELAPSED 166s (fully CPU-bound). Never returns; killed with `kill -9`. No `EPS_OK`/`EPS_FAIL`, no `.eps` file. |
| has-display (`DISPLAY=:0`, wayland) | Exits `rc=0` silently. No stdout, no stderr, no `.eps` file. Instrumented build reaches stage `before dataWithEPSInsideRect` then the process terminates (exit 0) without ever reaching the `after dataWithEPSInsideRect` stage. |
| Xvfb (`DISPLAY=:99`, timeout 45) | Same as has-display: `rc=0`, no stdout, no stderr, no `.eps` file. |

Stability verdict: **N/A / not reached** — no EPS output was produced under any
environment, so the two display-unset runs could not be diffed. `STABLE` cannot
be asserted; `DIFFERS` does not apply either. Draw-ops-present grep: N/A (no
file).

Root cause (from source, not a substituted API): `dataWithEPSInsideRect:`
(`NSView.m:4023`) delegates to
`[[NSPrintOperation EPSOperationWithView:insideRect:toData:] runOperation]`,
i.e. the whole GSPrinting print-operation pipeline. In this build that
`runOperation` never returns to the caller: display-unset it busy-spins; with a
display present the process exits 0 from inside the call without producing data.
So the EPS draw-op-stream mechanism is **NOT usable** for headless op capture in
gui 0.32 as installed. Per the spike rule, no alternative API was substituted;
the failure is recorded as-is.

**Exploratory note (labelled deviation, not part of the probe):** the exit-0
with a display, versus a busy-spin without one, points at `NSPrintOperation
runOperation` / the GSPrinting bundle as the failing component rather than
`NSView` itself. `dataWithPDFInsideRect:` (`NSView.m:4049`) uses the identical
`runOperation` pattern and would be expected to fail the same way; it was not
probed. This changes the Tier C mechanism away from the EPS op-stream toward the
bitmap path (Probe A, which DID work headless) or a lower-level
GSStreamContext/DPS approach that bypasses `NSPrintOperation`.

## Probe C — window + event injection under Xvfb

_(pending)_
