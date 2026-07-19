# libs-gui Headless Harness (Phase 0b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give libs-gui a headless-backend CI lane so its test suite actually *runs* (not SKIPs) in CI, plus the shared conveniences and a reference NSView test that the heavy-class Tier A/B suites will build on — then package it for Fred's buy-in.

**Architecture:** The spike proved the cairo backend renders offscreen with no display, so `[NSApplication sharedApplication]` succeeds headless and the existing `START_SET`/`SKIP` guard no longer fires — tests run instead of skipping. Phase 0b installs a cairo backend in a CI job with no display, runs the gui `make check`, and adds a small reference test and a geometry-assertion helper. Tier C render-regression is out of scope here (deferred to 0c: its capture mechanism is unresolved).

**Tech Stack:** GNUstep (base 1.31, gui 0.32, back-032 cairo) at `/usr/local`; clang; libobjc2 4.6; GNUstep `Testing.h`/`ObjectTesting.h` test framework; GitHub Actions; WSL Ubuntu for local proof.

## Global Constraints

- **Contribution discipline (binds every task and every subagent).** Any artifact that reaches an upstream GNUstep repository — test or source code, code comments, commit messages, PR titles and bodies, issue text — must: carry no AI/Claude attribution in any form (no `Co-Authored-By`, no robot emoji, no "Generated with"; commits authored as `Todd White <todd.white@thalion.global>` with no trailers); read as Todd White's own writing, factual and terse, with no LLM style tells (no bold section headers, pervasive bullet lists, rule-of-three, em-dash drama, signposting, or closing offers); contain no internal tracking identifiers (RB-, TS-, PF-, BUG-) and none of our private process vocabulary ("coverage-as-audit", "oracle", "the campaign"); add no change-describing comments in source. Draft substantive upstream prose for Todd's review before posting.
- **Environment:** WSL Ubuntu, GNUstep at `/usr/local`. Invoke from PowerShell as `wsl -d Ubuntu -- bash -lc '...'`.
- **Shell hazard:** inside `wsl … bash -lc '...'`, no inline `for VAR in …` loops or reused custom `$VAR` (they come back empty through the layers) — use script files or literal paths. `/tmp` is tmpfs (wiped on teardown) — use `$HOME`.
- **libs-gui tree:** `~/gnustep-reaudit/libs-gui` (fork `DTW-Thalion`, upstream `gnustep`). Build with `. /usr/local/share/GNUstep/Makefiles/GNUstep.sh` then `make -j$(nproc)`; test with `LD_LIBRARY_PATH=Source/obj:/usr/local/lib gnustep-tests gui/<Class>/<t>.m` or `make check` in `Tests`.
- **Headless simulation:** `env -u DISPLAY -u WAYLAND_DISPLAY`. The box is WSLg (`DISPLAY=:0` present); the CI job is the authoritative display-less environment.
- **Push:** WSL git hangs on HTTPS — push with Windows git: `"/c/Program Files/Git/bin/git.exe" -C "//wsl.localhost/Ubuntu/home/toddw/gnustep-reaudit/libs-gui" push …`. Commits authored in WSL as Todd White.
- **Backend SKIP guard stays:** do not remove the `START_SET` + `NS_HANDLER→SKIP` guard from tests — with a backend present it is inert and tests run; without one they still SKIP cleanly. The CI lane provides the backend.

---

## File Structure

- `~/gnustep-reaudit/libs-gui/.github/workflows/` — add a headless-backend job to the existing gui CI workflow (exact file discovered in Task 2).
- `~/gnustep-reaudit/libs-gui/Tests/gui/NSView/geometry.m` — reference Tier A geometry test (the pattern later suites copy).
- `~/gnustep-reaudit/libs-gui/Tests/gui/GNUmakefile` / `TestInfo` — wire the new test dir if needed.
- `C:\Users\toddw\source\repos\gnustep-audit\docs\spikes\2026-07-18-libs-gui-tierc-capture.md` — Tier C mechanism probe result (Task 5, informs the 0c plan; not built here).
- `C:\Users\toddw\Downloads\libs-gui-headless-ci-proposal-draft.md` — the Fred proposal draft (Task 6, for Todd's review; not posted).

---

### Task 1: Prove the gui suite runs headless with the cairo backend (local)

**Files:**
- None created; this establishes the CI recipe.

**Interfaces:**
- Produces: the exact command sequence that runs the gui test suite with a backend and no display, and a count of tests that RUN vs SKIP — the recipe Task 2 encodes into CI.

- [ ] **Step 1: Run one existing gui test headless and confirm it does NOT skip**

Run:
```
wsl -d Ubuntu -- bash -lc 'cd ~/gnustep-reaudit/libs-gui && git checkout master 2>/dev/null; . /usr/local/share/GNUstep/Makefiles/GNUstep.sh && export LD_LIBRARY_PATH=/usr/local/lib && env -u DISPLAY -u WAYLAND_DISPLAY gnustep-tests Tests/gui/NSPathControl/editable.m 2>&1 | grep -iE "passed|skipped|failed"'
```
Expected: `Passed`, NOT `Skipped`. This confirms the installed cairo backend lets `sharedApplication` succeed with no display so the SKIP guard stays inert. If it prints `Skipped`, record it — the backend is not initialising headless and Task 2 must add Xvfb.

- [ ] **Step 2: Run the whole gui `make check` headless and count run-vs-skip**

Run:
```
wsl -d Ubuntu -- bash -lc 'cd ~/gnustep-reaudit/libs-gui/Tests && . /usr/local/share/GNUstep/Makefiles/GNUstep.sh && export LD_LIBRARY_PATH=/home/toddw/gnustep-reaudit/libs-gui/Source/obj:/usr/local/lib ADDITIONAL_LDFLAGS=-L/usr/local/lib && env -u DISPLAY -u WAYLAND_DISPLAY gnustep-tests gui 2>&1 | tail -20'
```
Expected: a summary with many `Passed` and few/no `Skipped` sets. Record the totals (the current baseline with a headless backend).

- [ ] **Step 3: Record the recipe**

Note the exact env (`LD_LIBRARY_PATH`, `ADDITIONAL_LDFLAGS`, `env -u DISPLAY`) and the run/skip counts in the findings doc `docs/spikes/2026-07-18-libs-gui-headless-render.md` under a "0b: headless make check" heading. Commit to `gnustep-audit`:
```
cd C:\Users\toddw\source\repos\gnustep-audit
git add docs/spikes/2026-07-18-libs-gui-headless-render.md
git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "spike: 0b headless make check recipe + run/skip baseline"
```

---

### Task 2: Add a headless-backend CI job to the libs-gui workflow

**Files:**
- Modify: the existing gui CI workflow under `~/gnustep-reaudit/libs-gui/.github/workflows/` (discover the filename in Step 1).

**Interfaces:**
- Consumes: the Task 1 recipe (backend + `env -u DISPLAY` + make check).
- Produces: a CI job that builds gui against a cairo backend and runs `make check` with no display, so the suite runs instead of skipping.

- [ ] **Step 1: Read the existing workflow**

Run:
```
wsl -d Ubuntu -- bash -lc 'ls ~/gnustep-reaudit/libs-gui/.github/workflows/ && echo "---" && sed -n "1,120p" ~/gnustep-reaudit/libs-gui/.github/workflows/*.yml'
```
Expected: the current CI (how it installs base/back, whether it runs `make check`, whether a backend is installed). Identify whether tests currently skip because no backend is installed.

- [ ] **Step 2: Add the headless job**

Add a job that mirrors the existing setup and additionally installs a cairo backend (`libs-back` graphics=cairo, or the distro `gnustep-back` cairo variant), builds gui, and runs `make check` with `DISPLAY` unset. Use the existing workflow's setup steps verbatim where possible; the only additions are installing/selecting the cairo backend and running the check step with no display. Follow the repo's YAML style.

- [ ] **Step 3: Validate on a fork branch**

Create branch `ci/headless-gui-tests`, push to `DTW-Thalion` via Windows git, and confirm the new job runs the gui tests (not skips) on the GitHub runner:
```
wsl -d Ubuntu -- bash -lc 'cd ~/gnustep-reaudit/libs-gui && git checkout -b ci/headless-gui-tests && git add .github/workflows && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "ci: run gui tests headless against a cairo backend"'
"/c/Program Files/Git/bin/git.exe" -C "//wsl.localhost/Ubuntu/home/toddw/gnustep-reaudit/libs-gui" push myfork ci/headless-gui-tests
```
Then check the run:
```
gh run list --repo DTW-Thalion/libs-gui --branch ci/headless-gui-tests --limit 1
gh run view --repo DTW-Thalion/libs-gui <run-id> --log | grep -iE "passed|skipped|failed" | tail -20
```
Expected: the headless job runs the gui tests (Passed counts > 0, Skipped near zero). If tests still skip on the runner (WSLg leaked a socket locally but the runner has none), add `Xvfb :99 & export DISPLAY=:99` to the job as the contingency the spike identified, and re-validate.

- [ ] **Step 4: Commit state**

The workflow change is committed on `ci/headless-gui-tests`. Record the run result (run/skip counts on the real runner) in the findings doc and commit to `gnustep-audit` as in Task 1 Step 3.

---

### Task 3: Reference NSView geometry test (the pattern for Tier A)

**Files:**
- Create: `~/gnustep-reaudit/libs-gui/Tests/gui/NSView/geometry.m`
- Create/Modify: `~/gnustep-reaudit/libs-gui/Tests/gui/NSView/TestInfo` (empty) if the dir is new.

**Interfaces:**
- Consumes: the headless backend (Task 1/2) and the macOS oracle values.
- Produces: the canonical shape a heavy-class Tier A test takes — deterministic geometry assertions, backend SKIP guard, `PASS`/`PASS_EQUAL`.

- [ ] **Step 1: Oracle the values on macOS, then write the test**

Oracle `-[NSView convertRect:toView:]` and flipped-coordinate behaviour on the macOS runner for a fixed hierarchy, then write:

```objc
#import "Testing.h"
#import <Foundation/NSGeometry.h>
#import <AppKit/NSApplication.h>
#import <AppKit/NSView.h>
#import <AppKit/NSWindow.h>

int main(int argc, const char **argv)
{
  CREATE_AUTORELEASE_POOL(arp);
  START_SET("NSView geometry")

  NS_DURING
    [NSApplication sharedApplication];
  NS_HANDLER
    if ([[localException name] isEqualToString: NSInternalInconsistencyException])
      SKIP("It looks like GNUstep backend is not yet installed")
  NS_ENDHANDLER

  NSWindow *w = AUTORELEASE([[NSWindow alloc]
    initWithContentRect: NSMakeRect(0, 0, 200, 200)
              styleMask: NSWindowStyleMaskBorderless
                backing: NSBackingStoreBuffered
                  defer: NO]);
  NSView *outer = [w contentView];
  NSView *inner = AUTORELEASE([[NSView alloc]
    initWithFrame: NSMakeRect(50, 30, 100, 100)]);
  [outer addSubview: inner];

  /* A rect in inner's coordinates, expressed in outer's coordinates, is
     offset by inner's origin (both views unflipped). Values verified on
     AppKit. */
  NSRect r = [inner convertRect: NSMakeRect(10, 10, 20, 20) toView: outer];
  PASS(NSEqualRects(r, NSMakeRect(60, 40, 20, 20)),
    "convertRect:toView: offsets by the subview origin");

  NSRect back = [outer convertRect: r toView: inner];
  PASS(NSEqualRects(back, NSMakeRect(10, 10, 20, 20)),
    "convertRect:toView: round-trips");

  PASS([inner isFlipped] == NO, "a plain NSView is not flipped");

  END_SET("NSView geometry")
  DESTROY(arp);
  return 0;
}
```

- [ ] **Step 2: Run it headless (must PASS, not SKIP)**

Run:
```
wsl -d Ubuntu -- bash -lc 'cd ~/gnustep-reaudit/libs-gui/Tests && . /usr/local/share/GNUstep/Makefiles/GNUstep.sh && export LD_LIBRARY_PATH=/home/toddw/gnustep-reaudit/libs-gui/Source/obj:/usr/local/lib ADDITIONAL_LDFLAGS=-L/usr/local/lib && env -u DISPLAY -u WAYLAND_DISPLAY gnustep-tests gui/NSView/geometry.m 2>&1 | grep -iE "passed|skipped|failed"'
```
Expected: `3 Passed tests`, no `Skipped`. If a `PASS` fails, the oracle value and the GNUstep result diverge — that is a real Tier A finding; record it (candidate fix PR) rather than editing the expected value to match GNUstep.

- [ ] **Step 3: Commit the reference test**

```
wsl -d Ubuntu -- bash -lc 'cd ~/gnustep-reaudit/libs-gui && git add Tests/gui/NSView/geometry.m Tests/gui/NSView/TestInfo && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "tests: add NSView geometry tests"'
```
(Keep this on a `tests/nsview-geometry` branch off master, separate from the CI branch, so it can be a standalone coverage PR later.)

---

### Task 4: Draft the CI-lane proposal to Fred

**Files:**
- Create: `C:\Users\toddw\Downloads\libs-gui-headless-ci-proposal-draft.md`

**Interfaces:**
- Consumes: the Task 2 CI result (tests now run in CI).
- Produces: a draft issue/PR body for Todd to review and post — the buy-in gate before building heavy-class suites.

- [ ] **Step 1: Write the draft**

Write a plain, terse proposal (no LLM tells, no attribution, no internal vocabulary) stating: the gui test suite currently skips in CI because no backend is installed; installing a cairo backend and running `make check` with no display makes the suite run (with the run/skip numbers from Task 2 as evidence); it needs no display server (cairo renders to in-memory surfaces), with Xvfb only as a contingency for event-loop tests; proposing to add the job to the libs-gui CI. Keep it to what the change is and the evidence, not how it was developed.

- [ ] **Step 2: Stop for Todd's review**

Do not post. The plan ends here for the implementer; Todd reviews the draft and decides whether it goes to Fred as an issue or a PR against the CI branch from Task 2.

---

### Task 5 (research, feeds 0c): Tier C capture mechanism probe

**Files:**
- Create: `~/gnustep-reaudit/.spike-headless-gui/probeD_dps.m`
- Create: `C:\Users\toddw\source\repos\gnustep-audit\docs\spikes\2026-07-18-libs-gui-tierc-capture.md`

**Interfaces:**
- Produces: a decision for the 0c plan — op-stream capture (font-robust) vs offscreen-bitmap (proven, text-fragile).

- [ ] **Step 1: Probe an op-stream capture that bypasses NSPrintOperation**

Write a probe that creates a stream/DPS context on a memory buffer, makes it current, renders a `Box : NSView` (solid fill) via `-[NSView displayRectIgnoringOpacity:inContext:]`, and inspects the captured bytes. Try `NSDPSContext` with an output stream first; if that class/path is unavailable headless, record it. Run display-unset with a timeout (the EPS path hung — guard against it):
```
wsl -d Ubuntu -- bash -lc 'cd ~/gnustep-reaudit/.spike-headless-gui && . /usr/local/share/GNUstep/Makefiles/GNUstep.sh && clang probeD_dps.m -o probeD -L/usr/local/lib $(gnustep-config --objc-flags) $(gnustep-config --gui-libs) -lobjc 2>&1 | tail -3 && export LD_LIBRARY_PATH=/usr/local/lib && env -u DISPLAY -u WAYLAND_DISPLAY timeout 20 ./probeD; echo rc=$?'
```
Expected: either a captured op-stream (record whether it is stable across two runs and contains recognisable ops) or a clean failure (record it). Do not substitute APIs silently.

- [ ] **Step 2: Record the Tier C decision**

Write `docs/spikes/2026-07-18-libs-gui-tierc-capture.md`: op-stream viable (→ 0c builds the op-stream capture+compare helper) or not (→ 0c builds offscreen-bitmap regression scoped to non-text regions, with Tier A geometry carrying text correctness). Commit to `gnustep-audit` as Todd White.

---

## Definition of Done

- gui tests proven to run (not skip) headless locally (Task 1) and on the CI runner (Task 2).
- The headless CI job is on `ci/headless-gui-tests` and validated.
- A reference NSView geometry test exists, passes headless, and models the Tier A pattern (Task 3).
- The Fred proposal is drafted for Todd's review, not posted (Task 4).
- The Tier C capture mechanism is decided for the 0c plan (Task 5).
- Everything upstream-bound follows the contribution discipline. Deferred: Tier C helper + heavy-class suites (0c and Phase 1).
