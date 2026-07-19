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

Source: `~/gnustep-reaudit/.spike-headless-gui/probeC_event.m`.
`sharedApplication` + borderless `NSWindow` + `orderFront:` + synthetic
`NSEventTypeLeftMouseDown` via `mouseEventWithType:…` + `contentView hitTest:`.

Compiled: **YES**, exit 0, no warnings/errors. Binary 51648 bytes.

Run command (Xvfb, primary):
```
cd ~/gnustep-reaudit/.spike-headless-gui; export LD_LIBRARY_PATH=/usr/local/lib
Xvfb :99 -screen 0 1024x768x24 >/dev/null 2>&1 & sleep 1
DISPLAY=:99 timeout 45 ./probeC
# also tried display-unset:
env -u DISPLAY -u WAYLAND_DISPLAY timeout 30 ./probeC
```

Verbatim marker output:

| Environment | Marker |
|---|---|
| Xvfb (`DISPLAY=:99`) | `WINDOW_OK hit=yes event=yes` (rc=0) |
| display-unset (`env -u DISPLAY -u WAYLAND_DISPLAY`) | `WINDOW_OK hit=yes event=yes` (rc=0) |

**Finding: window creation, `orderFront:`, synthetic `NSEvent` construction,
and `hitTest:` all succeed under Xvfb — and also with no display at all.**
Hit-testing returns a non-nil view (`hit=yes`), so it resolves from view
geometry and does not require a mapped/on-screen window. The event object is
constructed successfully (`event=yes`). Note the probe constructs and hit-tests
but does not dispatch the event through the run loop / `sendEvent:`; driving a
full event through `-[NSApplication sendEvent:]` and observing an action is a
larger step this probe does not cover. Within its scope, the Tier B primitives
(real window + synthetic event + hit-test) are feasible in the Xvfb lane, and
the geometry parts even run display-less.

## Decision — tier to mechanism, and verdict

Verified independently after the sweep (re-ran each probe display-unset): Probe A
`BITMAP_OK`, Probe C `WINDOW_OK hit=yes event=yes`, Probe B no marker.

Verdict: **GO (headless-first), and broader than the spec assumed.** The cairo
backend renders into in-memory surfaces with no display, so offscreen bitmaps,
window creation, hit-testing, and synthetic event construction all work
display-less. Xvfb is not needed for these.

| Tier | Mechanism | Environment | Evidence |
|---|---|---|---|
| A — geometry / state / coding | direct API; offscreen context where one is needed | display-less | Probe A, C |
| B — window, hit-test, geometry | headless cairo backend | display-less | Probe C |
| B — full event dispatch via `sendEvent:` | Xvfb lane (contingency) | Xvfb | not proven; Probe C covered construction + hit-test only |
| C — render regression | offscreen bitmap (Probe A); comparison strategy resolved in the harness plan | display-less | Probe A |

Overturned assumption: the planned Tier C mechanism — draw-op stream via
`dataWithEPSInsideRect:` — is dead (`NSPrintOperation runOperation` hangs
display-less, exits 0 without data with a display). Shelved.

Residual (bounded, for the harness plan): Tier C's comparison strategy is the one
open mechanism. Harness plan task 1 probes a font-robust op capture that bypasses
the print pipeline — a `GSStreamContext` / `NSDPSContext` on a memory stream, set
current, view rendered via `displayRectIgnoringOpacity:inContext:`. If that yields
a stable PostScript op-stream headless, use it; otherwise fall back to offscreen
bitmap regression scoped to solid/shape regions (glyph pixels excluded for
freetype/AA variance), with per-environment baselines, and let Tier A geometry
(glyph and line rects) carry text-layout correctness instead of glyph pixels.

Xvfb: demoted from "required for Tier B" to a contingency lane — for full
event-loop dispatch, and as a fallback if a truly display-less CI runner behaves
differently from WSLg display-unset. The harness's first real CI run is the
authoritative confirmation.

## 0b: headless make check

Captured 2026-07-19 on the same WSL Ubuntu box, `~/gnustep-reaudit/libs-gui`,
branch `master` (left untouched, HEAD `db36c650f`, working tree clean, 108
commits behind `origin/master`).

### Step 1: single test

The planned command was:

```
env -u DISPLAY -u WAYLAND_DISPLAY gnustep-tests Tests/gui/NSPathControl/editable.m
```

This does not run: `Tests/gui/NSPathControl/editable.m` does not exist at the
checked-out commit. `git ls-tree HEAD Tests/gui/NSPathControl/` is empty; the
directory on disk (`GNUmakefile`, `obj/pathitems*`) is untracked build residue
from a prior session, not part of this commit's tree. `editable.m` exists on
`origin/master` (added in `237f4fdd0`, "Fix: NSPathControl -isEditable
/-setEditable:"), 108 commits ahead of the checked-out HEAD. Did not pull to
fetch it: that would move the baseline commit out from under an otherwise
unrelated task, and the question Step 1 exists to answer doesn't need that
specific file.

Substituted an existing tracked test that also exercises `sharedApplication`
(the same SKIP-guard path): `Tests/gui/NSApplication/basic.m` fails to build
independent of the backend question (`error: use of undeclared identifier
'NSProcessInfo'`, missing `#import <Foundation/NSProcessInfo.h>`). Fell back to
`Tests/gui/NSButtonCell/stateValue.m`:

```
cd ~/gnustep-reaudit/libs-gui
. /usr/local/share/GNUstep/Makefiles/GNUstep.sh
export LD_LIBRARY_PATH=/usr/local/lib
env -u DISPLAY -u WAYLAND_DISPLAY gnustep-tests Tests/gui/NSButtonCell/stateValue.m
```

Result: `14 Passed tests`, `All OK!`. No `Skipped`. Confirms the cairo backend
initialises `sharedApplication` with no `DISPLAY`/`WAYLAND_DISPLAY` set, so the
SKIP guard in gui view tests stays inert and the tests actually run.

### Step 2: whole gui `make check`

Ran verbatim:

```
cd ~/gnustep-reaudit/libs-gui/Tests
. /usr/local/share/GNUstep/Makefiles/GNUstep.sh
export LD_LIBRARY_PATH=/home/toddw/gnustep-reaudit/libs-gui/Source/obj:/usr/local/lib ADDITIONAL_LDFLAGS=-L/usr/local/lib
env -u DISPLAY -u WAYLAND_DISPLAY gnustep-tests gui
```

No rebuild was needed; `Source/obj` from the prior session loaded fine.

Final summary block:

```
   2000 Passed tests
     15 Failed tests
      4 Failed builds
      2 Failed files
      2 Dashed hopes
      1 Failed set
```

`Skipped` occurs zero times anywhere in the full run output (`grep -ic skipped`
on the captured log returns `0`). So of the tests that build and run, none are
being SKIP-guarded out headless: the 2000 passes are real runs, not
vacuously-skipped sets. Exit code of `gnustep-tests gui` itself is 0 despite the
failures (the tool reports failures in its summary text, not via exit status).

Failures are pre-existing content/logic issues in this stale (108-behind)
tree, unrelated to headless-vs-display:

- 4 failed builds: `gui/GSCodingFlags/GSCellFlags.m` (`GSCodingFlags.h` file not
  found), `gui/GSXib5KeyedUnarchiver/buttonCell.m` and `menu.m`
  (`Additions/GNUstepGUI/GSXibKeyedUnarchiver.h` file not found),
  `gui/NSApplication/basic.m` (undeclared `NSProcessInfo`, missing import).
- 2 failed files (aborted mid-run): `gui/NSFormCell/title.m`,
  `gui/NSTextFieldCell/attributes.m`.
- 15 failed tests across `gui/NSDatePickerCell/{clamping,defaultColors,
  defaultDateValue,defaultElements}.m` and `gui/NSLevelIndicatorCell/{initStyle,
  levelIndicatorStyle,tickMarkValue}.m`: cell-default/clamping assertions, not
  backend-related.
- 1 failed set: `gui/NSDataLink/basic.m`.
- 2 "Dashed hopes" tied to the aborted files above.

### Recipe (for Task 2 CI encoding)

```
. /usr/local/share/GNUstep/Makefiles/GNUstep.sh
export LD_LIBRARY_PATH=<repo>/Source/obj:/usr/local/lib
export ADDITIONAL_LDFLAGS=-L/usr/local/lib
env -u DISPLAY -u WAYLAND_DISPLAY gnustep-tests gui
```

No `Xvfb` in this recipe. The default installed backend (cairo bundle) needs
neither `DISPLAY` nor `WAYLAND_DISPLAY` for `gnustep-tests gui` to build and run
the suite for real (0 skips). Baseline for Task 2's CI job: expect on the order
of 2000 passed / 0 skipped on a fresh, up-to-date checkout; the 15
failed/4 failed-build/2 failed-file counts recorded here are artifacts of this
tree being 108 commits behind origin master and should not recur once CI runs
against current master.
