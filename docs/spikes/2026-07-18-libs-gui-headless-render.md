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

_(pending)_

## Probe C — window + event injection under Xvfb

_(pending)_
