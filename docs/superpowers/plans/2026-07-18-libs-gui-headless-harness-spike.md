# libs-gui Headless Harness Spike (Phase 0a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Answer the gating question of the heavy-class testing strategy — *can GNUstep render offscreen and capture drawing operations in a display-less (CI) environment?* — and produce a minimal working proof plus a tier→mechanism decision that the harness plan (Phase 0b) is built on.

**Architecture:** This is a spike, not shippable software. It compiles throwaway ObjC probes against the installed GNUstep stack in WSL, runs each probe under three environments (has-display, display-unset, Xvfb), and records what works. The deliverable is a findings/decision document committed to the planning repo. Each probe's "test" is *running it and observing the recorded marker output* — there is no pre-known assertion, because the outcome is exactly what we are trying to learn.

**Tech Stack:** GNUstep (base 1.31, gui 0.32, back-032, cairo/x11-or-wayland) at `/usr/local`; clang; libobjc2 4.6; ng-gnu-gnu / gnustep-2.0; WSL Ubuntu; Xvfb; the macOS-oracle GitHub Actions infra (for the optional CI-headless confirmation).

## Global Constraints

- **Environment:** WSL Ubuntu, GNUstep installed at `/usr/local`. Invoke from PowerShell as `wsl -d Ubuntu -- bash -lc '...'`.
- **Shell hazard:** inline `for VAR in …` loops and custom `$VAR` come back EMPTY through the PowerShell→wsl→bash layers — use a script file or literal paths, never inline loops/vars.
- **tmpfs:** `/tmp` is wiped on WSL idle-teardown — write all probe outputs under `$HOME`, never `/tmp`.
- **Compile recipe:** `. /usr/local/share/GNUstep/Makefiles/GNUstep.sh` then `clang probe.m -o probe -L/usr/local/lib $(gnustep-config --objc-flags) $(gnustep-config --gui-libs) -lobjc`. `-L/usr/local/lib` MUST come before `-lobjc` so it resolves to libobjc2 `libobjc.so.4.6`, not gcc's shadow.
- **Headless simulation:** the box runs WSLg with `DISPLAY=:0` always present. Simulate display-less with `env -u DISPLAY -u WAYLAND_DISPLAY ./probe`. This is an approximation; a truly display-less GitHub Actions ubuntu job is the authoritative gate and is an optional confirmation step (Task 6).
- **Xvfb:** `/usr/bin/Xvfb`. Start with `Xvfb :99 -screen 0 1024x768x24 >/dev/null 2>&1 & sleep 1; export DISPLAY=:99`.
- **ObjC exceptions:** use `NS_DURING`/`NS_HANDLER`, never `@try`/`@catch` (Win32 rule, kept for consistency).
- **Spike code is throwaway:** lives in `~/gnustep-reaudit/.spike-headless-gui/` (untracked, WSL-side). Only the **findings document** is committed, to `docs/spikes/2026-07-18-libs-gui-headless-render.md` in the `gnustep-audit` repo, authored as `Todd White <todd.white@thalion.global>`, no AI attribution.
- **No pixel-checksums for text** (freetype/cairo version variance). Determinism checks use solid-colour fills only.

---

## File Structure

- `~/gnustep-reaudit/.spike-headless-gui/probeA_bitmap.m` — offscreen bitmap render probe (Tier C / bitmap path).
- `~/gnustep-reaudit/.spike-headless-gui/probeB_eps.m` — `dataWithEPSInsideRect:` draw-op-stream probe (Tier C / draw-op path, the preferred mechanism).
- `~/gnustep-reaudit/.spike-headless-gui/probeC_event.m` — window + event-injection probe (Tier B feasibility).
- `~/gnustep-reaudit/.spike-headless-gui/run.sh` — driver that compiles and runs each probe under has-display / display-unset / Xvfb and prints markers.
- `C:\Users\toddw\source\repos\gnustep-audit\docs\spikes\2026-07-18-libs-gui-headless-render.md` — findings + decision (the committed deliverable).

---

### Task 1: Spike workspace + backend confirmation

**Files:**
- Create: `~/gnustep-reaudit/.spike-headless-gui/` (dir)
- Create: `C:\Users\toddw\source\repos\gnustep-audit\docs\spikes\2026-07-18-libs-gui-headless-render.md`

**Interfaces:**
- Produces: the findings doc with an "Environment" section that later tasks append observations to.

- [ ] **Step 1: Create the workspace and confirm the graphics backend**

Run:
```
wsl -d Ubuntu -- bash -lc 'mkdir -p ~/gnustep-reaudit/.spike-headless-gui && . /usr/local/share/GNUstep/Makefiles/GNUstep.sh && echo "gui-libs: $(gnustep-config --gui-libs)"; defaults read NSGlobalDomain GSBackend 2>/dev/null; echo "back bundle Info:"; cat /usr/local/lib/GNUstep/Bundles/libgnustep-back-032.bundle/Resources/Info-gnustep.plist 2>/dev/null | grep -iE "graphics|server|GSBackend" '
```
Expected: prints the gui link flags and any graphics/server keys identifying the backend variant (cairo + x11 or wayland).

- [ ] **Step 2: Record the environment**

Write the "Environment" section of the findings doc: GNUstep versions, backend variant, `DISPLAY=:0` (WSLg), Xvfb present, and the note that CI is the authoritative headless gate.

- [ ] **Step 3: Commit the findings skeleton**

```
cd C:\Users\toddw\source\repos\gnustep-audit
git add docs/spikes/2026-07-18-libs-gui-headless-render.md
git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "spike: libs-gui headless render — environment"
```

---

### Task 2: Probe A — offscreen bitmap render, display-less vs Xvfb

**Files:**
- Create: `~/gnustep-reaudit/.spike-headless-gui/probeA_bitmap.m`

**Interfaces:**
- Produces: a definitive Y/N for "can `sharedApplication` + `NSImage lockFocus` + `NSBitmapImageRep` produce a bitmap with no display."

- [ ] **Step 1: Write the probe**

```objc
#import <AppKit/AppKit.h>
#include <stdio.h>

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NS_DURING
    {
      [NSApplication sharedApplication];
      NSImage *img = [[NSImage alloc] initWithSize: NSMakeSize(20, 20)];
      [img lockFocus];
      [[NSColor redColor] set];
      NSRectFill(NSMakeRect(0, 0, 20, 20));
      NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithFocusedViewRect: NSMakeRect(0, 0, 20, 20)];
      [img unlockFocus];
      NSData *png = [rep representationUsingType: NSPNGFileType properties: nil];
      [png writeToFile: [@"~/probeA.png" stringByExpandingTildeInPath] atomically: YES];
      printf("BITMAP_OK bytes=%lu\n", (unsigned long)[png length]);
    }
  NS_HANDLER
    printf("BITMAP_FAIL %s\n", [[localException reason] UTF8String]);
  NS_ENDHANDLER
  [arp release];
  return 0;
}
```

- [ ] **Step 2: Compile it**

Run:
```
wsl -d Ubuntu -- bash -lc 'cd ~/gnustep-reaudit/.spike-headless-gui && . /usr/local/share/GNUstep/Makefiles/GNUstep.sh && clang probeA_bitmap.m -o probeA -L/usr/local/lib $(gnustep-config --objc-flags) $(gnustep-config --gui-libs) -lobjc 2>&1 | tail -5; echo exit $?'
```
Expected: compiles (exit 0). If it fails to link, record the error — that itself is a finding about the API surface.

- [ ] **Step 3: Run under all three environments and record**

Run:
```
wsl -d Ubuntu -- bash -lc 'cd ~/gnustep-reaudit/.spike-headless-gui && export LD_LIBRARY_PATH=/usr/local/lib && echo "== has-display =="; ./probeA; echo "== display-unset =="; env -u DISPLAY -u WAYLAND_DISPLAY ./probeA; echo "== xvfb =="; Xvfb :99 -screen 0 1024x768x24 >/dev/null 2>&1 & sleep 1; DISPLAY=:99 ./probeA; kill %1 2>/dev/null'
```
Expected: three lines, each `BITMAP_OK bytes=…` or `BITMAP_FAIL <reason>`. **Record which environments produced OK.** The likely-informative outcome: OK with a display (has-display/xvfb), FAIL display-unset (backend needs an X/wayland connection at init) — which tells us the bitmap path is *not* headless and must use Xvfb, pushing Tier C onto the draw-op path (Task 3).

- [ ] **Step 4: Commit the finding**

```
cd C:\Users\toddw\source\repos\gnustep-audit
git add docs/spikes/2026-07-18-libs-gui-headless-render.md
git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "spike: probe A bitmap render — display dependence"
```
(Append the three-environment result to the findings doc before committing.)

---

### Task 3: Probe B — draw-op stream via `dataWithEPSInsideRect:` (the key path)

**Files:**
- Create: `~/gnustep-reaudit/.spike-headless-gui/probeB_eps.m`

**Interfaces:**
- Produces: Y/N for "can we capture a view's drawing as a PostScript op-stream with no display," plus a stability verdict (identical across two runs) and an assertability sample (the stream contains recognisable ops).

- [ ] **Step 1: Write the probe**

```objc
#import <AppKit/AppKit.h>
#include <stdio.h>

@interface Box : NSView
@end
@implementation Box
- (void) drawRect: (NSRect)r
{
  [[NSColor redColor] set];
  NSRectFill([self bounds]);
}
@end

int main(int argc, const char **argv)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSString *out = [NSString stringWithUTF8String: (argc > 1 ? argv[1] : "probeB.eps")];
  NS_DURING
    {
      Box *v = [[Box alloc] initWithFrame: NSMakeRect(0, 0, 20, 20)];
      NSData *eps = [v dataWithEPSInsideRect: [v bounds]];
      [eps writeToFile: [out stringByExpandingTildeInPath] atomically: YES];
      printf("EPS_OK len=%lu\n", (unsigned long)[eps length]);
    }
  NS_HANDLER
    printf("EPS_FAIL %s\n", [[localException reason] UTF8String]);
  NS_ENDHANDLER
  [arp release];
  return 0;
}
```

- [ ] **Step 2: Compile it**

Run:
```
wsl -d Ubuntu -- bash -lc 'cd ~/gnustep-reaudit/.spike-headless-gui && . /usr/local/share/GNUstep/Makefiles/GNUstep.sh && clang probeB_eps.m -o probeB -L/usr/local/lib $(gnustep-config --objc-flags) $(gnustep-config --gui-libs) -lobjc 2>&1 | tail -5; echo exit $?'
```
Expected: compiles (exit 0). If `dataWithEPSInsideRect:` is unavailable/unimplemented in this gui build, record that — it changes the Tier C mechanism to a lower-level GSStreamContext/DPS approach.

- [ ] **Step 3: Run display-unset (primary), check stability + assertability**

Run:
```
wsl -d Ubuntu -- bash -lc 'cd ~/gnustep-reaudit/.spike-headless-gui && export LD_LIBRARY_PATH=/usr/local/lib && echo "== display-unset run1 =="; env -u DISPLAY -u WAYLAND_DISPLAY ./probeB ~/probeB1.eps; echo "== display-unset run2 =="; env -u DISPLAY -u WAYLAND_DISPLAY ./probeB ~/probeB2.eps; echo "== stable? =="; diff <(grep -av "CreationDate\|Title\|BoundingBox" ~/probeB1.eps) <(grep -av "CreationDate\|Title\|BoundingBox" ~/probeB2.eps) >/dev/null && echo STABLE || echo DIFFERS; echo "== draw ops present? =="; grep -aiE "fill|rectfill|setrgbcolor|moveto|lineto|1 0 0" ~/probeB1.eps | head'
```
Expected: `EPS_OK` on both runs (if headless works for the DPS path), `STABLE` after masking volatile header lines (dates/titles), and grep showing recognisable drawing operations (a red fill). **This is the pivotal result** — if EPS capture works display-less and is stable, it is the Tier C (and Tier-A-geometry-via-context) mechanism.

- [ ] **Step 4: If display-unset FAILED, retry under Xvfb**

Run (only if Step 3 printed `EPS_FAIL`):
```
wsl -d Ubuntu -- bash -lc 'cd ~/gnustep-reaudit/.spike-headless-gui && export LD_LIBRARY_PATH=/usr/local/lib && Xvfb :99 -screen 0 1024x768x24 >/dev/null 2>&1 & sleep 1; DISPLAY=:99 ./probeB ~/probeB_x.eps; kill %1 2>/dev/null'
```
Expected: clarifies whether EPS needs *any* display or a specific one. Record.

- [ ] **Step 5: Commit the finding**

```
cd C:\Users\toddw\source\repos\gnustep-audit
git add docs/spikes/2026-07-18-libs-gui-headless-render.md
git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "spike: probe B EPS draw-op stream — headless + stability"
```

---

### Task 4: Probe C — window + event injection under Xvfb (Tier B feasibility)

**Files:**
- Create: `~/gnustep-reaudit/.spike-headless-gui/probeC_event.m`

**Interfaces:**
- Produces: Y/N for "can we create a real window and drive a mouse event through the run loop under Xvfb," bounding what Tier B can assert in the Xvfb lane.

- [ ] **Step 1: Write the probe**

```objc
#import <AppKit/AppKit.h>
#include <stdio.h>

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NS_DURING
    {
      [NSApplication sharedApplication];
      NSWindow *w = [[NSWindow alloc]
        initWithContentRect: NSMakeRect(0, 0, 100, 100)
                  styleMask: NSWindowStyleMaskBorderless
                    backing: NSBackingStoreBuffered
                      defer: NO];
      [w orderFront: nil];
      NSView *cv = [w contentView];
      NSPoint inWin = NSMakePoint(10, 10);
      NSEvent *e = [NSEvent mouseEventWithType: NSEventTypeLeftMouseDown
                                      location: inWin
                                 modifierFlags: 0
                                     timestamp: 0
                                  windowNumber: [w windowNumber]
                                       context: nil
                                   eventNumber: 0
                                    clickCount: 1
                                      pressure: 1.0];
      NSView *hit = [cv hitTest: [cv convertPoint: inWin fromView: nil]];
      printf("WINDOW_OK hit=%s event=%s\n",
        hit ? "yes" : "no", e ? "yes" : "no");
    }
  NS_HANDLER
    printf("WINDOW_FAIL %s\n", [[localException reason] UTF8String]);
  NS_ENDHANDLER
  [arp release];
  return 0;
}
```

- [ ] **Step 2: Compile and run under Xvfb**

Run:
```
wsl -d Ubuntu -- bash -lc 'cd ~/gnustep-reaudit/.spike-headless-gui && . /usr/local/share/GNUstep/Makefiles/GNUstep.sh && clang probeC_event.m -o probeC -L/usr/local/lib $(gnustep-config --objc-flags) $(gnustep-config --gui-libs) -lobjc 2>&1 | tail -3 && export LD_LIBRARY_PATH=/usr/local/lib && Xvfb :99 -screen 0 1024x768x24 >/dev/null 2>&1 & sleep 1; DISPLAY=:99 ./probeC; kill %1 2>/dev/null'
```
Expected: `WINDOW_OK hit=yes event=yes` under Xvfb (window creation, hit-testing, and synthetic event construction all work). Record whether hit-testing needs a real window/backend or works from geometry alone.

- [ ] **Step 3: Commit the finding**

```
cd C:\Users\toddw\source\repos\gnustep-audit
git add docs/spikes/2026-07-18-libs-gui-headless-render.md
git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "spike: probe C window + event under Xvfb — Tier B feasibility"
```

---

### Task 5: Tier→mechanism decision + architecture verdict

**Files:**
- Modify: `docs/spikes/2026-07-18-libs-gui-headless-render.md`
- Modify: `docs/superpowers/specs/2026-07-18-libs-gui-heavy-class-testing-design.md` (resolve the "gating unknown" and the headless-mechanism open question)

**Interfaces:**
- Consumes: the recorded results of Probes A/B/C.
- Produces: a decision table mapping each tier to a concrete mechanism, and a GO / FORK verdict for the harness plan.

- [ ] **Step 1: Fill the decision table**

Write into the findings doc, one row per tier, using the observed markers:

| Tier | Mechanism chosen | Environment | Evidence (probe + marker) |
|---|---|---|---|
| A (geometry/state/coding) | pure API (no context) or EPS-context | display-unset | Probe B result |
| C (render regression) | `dataWithEPSInsideRect:` op-stream | display-unset if Probe B OK, else Xvfb | Probe B / A |
| B (behavioural/events) | Xvfb+x11 lane | Xvfb | Probe C |

- [ ] **Step 2: Write the verdict**

State GO (headless-first viable: Tiers A/C run display-less via the EPS op-stream, Tier B in the Xvfb lane) or FORK (headless offscreen impossible: all rendering tiers need Xvfb — revise the harness plan to an Xvfb-for-everything design). Base it strictly on the recorded markers, not expectation.

- [ ] **Step 3: Update the spec's open questions**

In the design spec, replace the "gating unknown" and "exact headless mechanism" open questions with the resolved answer, and note the draw-op capture format decided (EPS via `dataWithEPSInsideRect:` vs a lower-level fallback).

- [ ] **Step 4: Commit**

```
cd C:\Users\toddw\source\repos\gnustep-audit
git add docs/spikes/2026-07-18-libs-gui-headless-render.md docs/superpowers/specs/2026-07-18-libs-gui-heavy-class-testing-design.md
git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "spike: tier→mechanism decision + resolve spec gating unknown"
```

---

### Task 6 (optional): CI-headless confirmation

**Files:**
- Create: a throwaway GitHub Actions workflow on a scratch branch of the `DTW-Thalion/libs-gui` fork that compiles and runs Probe B on a stock `ubuntu-latest` runner (truly display-less), OR run Probe B in a local `docker run --rm --network none ubuntu` container with the GNUstep stack.

**Interfaces:**
- Consumes: Probe B binary/source.
- Produces: confirmation that the display-unset result holds in a genuinely display-less environment (WSLg can leak sockets; this removes that doubt).

- [ ] **Step 1: Decide whether it is needed**

If Probe B was `EPS_OK` display-unset AND the harness plan will add a CI job anyway, skip this — the harness plan's first CI run is the confirmation. If the result was marginal or WSLg-socket doubt remains, do Step 2.

- [ ] **Step 2: Run Probe B in a no-display container**

Run:
```
wsl -d Ubuntu -- bash -lc 'command -v docker && docker run --rm --network none -v ~/gnustep-reaudit/.spike-headless-gui:/w -w /w <gnustep-image> bash -lc "clang probeB_eps.m -o probeB -L/usr/local/lib \$(gnustep-config --objc-flags) \$(gnustep-config --gui-libs) -lobjc && ./probeB /tmp/x.eps" || echo "no docker — use GitHub Actions scratch job instead"'
```
Expected: `EPS_OK` in a container with no X and no network. Record. (If no suitable image, note that the harness plan's CI job supersedes this.)

- [ ] **Step 3: Commit the confirmation**

```
cd C:\Users\toddw\source\repos\gnustep-audit
git add docs/spikes/2026-07-18-libs-gui-headless-render.md
git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "spike: CI-headless confirmation of EPS op-stream"
```

---

## Definition of Done

- Probes A, B, C compiled and run; every result recorded in the findings doc with the exact marker output.
- The tier→mechanism decision table is filled and a GO / FORK verdict written.
- The design spec's "gating unknown" and headless-mechanism open questions are resolved.
- Findings committed to `gnustep-audit`. Throwaway probe code remains untracked in WSL.
- Next step: write the **Phase 0b harness plan** on the decided mechanism (headless EPS op-stream helper + comparison, the Xvfb event lane, the CI job), then take the harness to Fred for buy-in.
