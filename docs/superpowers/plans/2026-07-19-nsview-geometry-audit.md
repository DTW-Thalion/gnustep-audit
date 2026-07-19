# NSView Geometry Audit and Suite Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Audit the full NSView geometry/coordinate surface against AppKit, and replace the scattered NSView geometry tests with clean, comprehensive, topic-grouped suites, shipping a green coverage PR plus separate fix PRs for confirmed divergences.

**Architecture:** A macOS oracle run captures AppKit ground-truth for a fixed set of geometry probes. Each probe becomes an assertion. Assertions GNUstep already satisfies form the green consolidated coverage suite (which absorbs and then deletes the old scattered files); assertions GNUstep fails are confirmed divergences that ship as separate fail-before/pass-after fix PRs. Windowless view math runs display-independent; window-touching tests carry a broadened skip guard.

**Tech Stack:** GNUstep libs-gui (`~/gnustep-reaudit/libs-gui`, WSL), `Testing.h`/`ObjectTesting.h`; clang; the cairo backend; GitHub Actions macOS runner (oracle) and the #602 xvfb lane (enforcement). Spec: `docs/superpowers/specs/2026-07-19-libs-gui-nsview-geometry-audit-design.md`.

## Global Constraints

- **Contribution discipline (binds every task and subagent).** Any artifact reaching an upstream GNUstep repo — test/source code, comments, commit messages, PR titles/bodies, issue text — must: carry no AI/Claude attribution (no `Co-Authored-By`, no robot emoji, no "Generated with"; commits authored as `Todd White <todd.white@thalion.global>` with no trailers); read as Todd White's own terse factual writing with no LLM style tells (no bold headers, bullet-list padding, rule-of-three, em-dash drama, signposting, closing offers); contain no internal tracking IDs (RB-/TS-/PF-/BUG-) and none of our private process vocabulary ("coverage-as-audit", "oracle", "the campaign"); add no change-describing comments in source (a fix site gets a short hazard note and a pointer to its test). The word "oracle" is our internal term — never put it in upstream text; upstream, say "the values were checked on macOS/AppKit". Draft substantive upstream prose for Todd's review before posting.
- **Oracle-gated values.** Expected values in the suite tasks are NOT hardcoded in this plan; they come from the macOS values recorded by Task 1 in `docs/oracle/2026-07-19-nsview-geometry.md` (gnustep-audit). Where an assertion built from a recorded macOS value FAILS on GNUstep, that is a confirmed divergence: record it, keep it OUT of the coverage suite, and route it to a fix PR (Tasks 8+). Never edit an expected value to match GNUstep.
- **Environment.** WSL Ubuntu, GNUstep at `/usr/local`; libs-gui tree `~/gnustep-reaudit/libs-gui` (fork remote `myfork` = DTW-Thalion, upstream `origin` = gnustep). Build: `. /usr/local/share/GNUstep/Makefiles/GNUstep.sh` then `make -j$(nproc)`. Run a test: `cd Tests && . /usr/local/share/GNUstep/Makefiles/GNUstep.sh && export LD_LIBRARY_PATH=/home/toddw/gnustep-reaudit/libs-gui/Source/obj:/usr/local/lib ADDITIONAL_LDFLAGS=-L/usr/local/lib && gnustep-tests gui/NSView/<file>.m`. `gnustep-tests` takes ONE file/dir arg.
- **Shell hazard.** Inside `wsl -d Ubuntu -- bash -lc '...'`: no inline `for VAR in` loops or reused custom `$VAR` (empty through the layers); use literal paths or script files. `/tmp` is tmpfs (wiped) — use `$HOME`.
- **Display reality (corrected).** `env -u DISPLAY -u WAYLAND_DISPLAY` does NOT go headless under WSLg (libwayland falls back to the live `wayland-0` socket). To run genuinely display-less locally: `DISPLAY=:99` plus `XDG_RUNTIME_DIR=<empty dir>`. Window-touching operations raise `NSWindowServerCommunicationException` display-less; windowless view math is display-independent, and only `convertPoint:` (not `convertRect:`) lacks the window guard in current code.
- **Push.** WSL git hangs on HTTPS; push with Windows git: `"/c/Program Files/Git/bin/git.exe" -C "//wsl.localhost/Ubuntu/home/toddw/gnustep-reaudit/libs-gui" push myfork <branch>`. Commits authored in WSL as Todd White.
- **Branching.** Coverage work on branch `tests/nsview-geometry-suite` off `origin/master`; each fix on its own `fix/nsview-<topic>` branch off `origin/master`. Keep coverage and fixes in separate branches/PRs.
- **Skip guard.** Keep the `sharedApplication` + NS_HANDLER→SKIP idiom. For any test that creates a window, broaden the guard to also `SKIP` on `@"NSWindowServerCommunicationException"` (string literal; not a declared constant), matching PR #601 `rendering.m`.

---

## Preconditions

- **#601 provenance.** `geometry.m` and `rendering.m` currently live only on the unmerged PR #601 branch (`tests/nsview-geometry`), not on `origin/master`. This plan folds `geometry.m` into `convert.m` and keeps `rendering.m`. Base the consolidation on whichever is true at execution time: if #601 has merged, branch `tests/nsview-geometry-suite` off `origin/master` (both files present — delete `geometry.m`, leave `rendering.m`). If #601 has NOT merged, branch off `origin/tests/nsview-geometry` (the #601 head) so both files are present, and rebase onto `origin/master` once #601 merges. Do not stack silently: note in the coverage PR that it supersedes/extends #601's `geometry.m`. Confirm the base at the start of Task 2 before creating any suite.

---

## File Structure

- `<oracle repo>/probes/nsview-geometry.m` — the macOS Cocoa probe (Task 1).
- `<oracle repo>/.github/workflows/oracle.yml` — macOS Actions runner that compiles and runs probes (Task 1, reusable for later classes).
- `docs/oracle/2026-07-19-nsview-geometry.md` (gnustep-audit) — recorded macOS values (Task 1); the source of every expected value below.
- `~/gnustep-reaudit/libs-gui/Tests/gui/NSView/convert.m` — coordinate conversion (Task 2).
- `~/gnustep-reaudit/libs-gui/Tests/gui/NSView/frameBounds.m` — frame/bounds (Task 3).
- `~/gnustep-reaudit/libs-gui/Tests/gui/NSView/rotation.m` — rotation (Task 4).
- `~/gnustep-reaudit/libs-gui/Tests/gui/NSView/autoresize.m` — autoresize (Task 5).
- `~/gnustep-reaudit/libs-gui/Tests/gui/NSView/visibleClip.m` — visibleRect/scroll (Task 6).
- Delete: `NSView_convertRect.m`, `NSView_frame_bounds.m`, `NSView_bounds_scale.m`, `NSView_setFrameSize_zero.m`, `NSView_frame_rotation.m`, `NSView_autoresize_and_rounding.m`, `NSView_visibleRect.m`, `scrollRectToVisible.m`, `geometry.m` (folded into `convert.m`).
- `~/gnustep-reaudit/libs-gui/Source/NSView.m` — fix site(s) for confirmed divergences (Tasks 8+).

---

### Task 1: Stand up the macOS oracle and sweep the NSView geometry surface

**Files:**
- Create (reusable oracle, in a dedicated fork repo `DTW-Thalion/gnustep-oracle` or a scratch branch never PR'd upstream): `probes/nsview-geometry.m`, `.github/workflows/oracle.yml`.
- Create: `docs/oracle/2026-07-19-nsview-geometry.md` (gnustep-audit) — the recorded values.

**Interfaces:**
- Produces: `docs/oracle/2026-07-19-nsview-geometry.md`, a table keyed by probe id (e.g. `convertRect.windowless.inner_to_outer`) → the AppKit value, consumed by every later suite task.

- [ ] **Step 1: Write the Cocoa probe**

Create `probes/nsview-geometry.m`. It builds views/windows with fixed inputs and prints one `id=value` line per probe to stdout. Values print with full precision. Complete starting content (extend with every case the suites need — the enumerated case lists are in Tasks 2-6):

```objc
#import <Cocoa/Cocoa.h>

static void P(NSString *id, NSString *val) { printf("%s = %s\n", [id UTF8String], [val UTF8String]); }
static NSString *R(NSRect r){ return NSStringFromRect(r); }
static NSString *Pt(NSPoint p){ return NSStringFromPoint(p); }
static NSString *Sz(NSSize s){ return NSStringFromSize(s); }

int main(void) { @autoreleasepool {
  [NSApplication sharedApplication];

  // windowless hierarchy
  NSView *outer = [[NSView alloc] initWithFrame: NSMakeRect(0,0,200,200)];
  NSView *inner = [[NSView alloc] initWithFrame: NSMakeRect(50,30,100,100)];
  [outer addSubview: inner];
  P(@"convertPoint.windowless.inner_to_outer", Pt([inner convertPoint: NSMakePoint(10,10) toView: outer]));
  P(@"convertRect.windowless.inner_to_outer",  R([inner convertRect: NSMakeRect(10,10,20,20) toView: outer]));
  P(@"convertSize.windowless.inner_to_outer",  Sz([inner convertSize: NSMakeSize(20,20) toView: outer]));

  // windowed hierarchy
  NSWindow *w = [[NSWindow alloc] initWithContentRect: NSMakeRect(0,0,200,200)
     styleMask: NSWindowStyleMaskBorderless backing: NSBackingStoreBuffered defer: NO];
  NSView *wOuter = [w contentView];
  NSView *wInner = [[NSView alloc] initWithFrame: NSMakeRect(50,30,100,100)];
  [wOuter addSubview: wInner];
  P(@"convertRect.windowed.inner_to_outer", R([wInner convertRect: NSMakeRect(10,10,20,20) toView: wOuter]));
  P(@"convertRect.windowed.inner_to_nil",   R([wInner convertRect: NSMakeRect(10,10,20,20) toView: nil]));

  return 0;
} }
```

- [ ] **Step 2: Write the macOS Actions workflow**

Create `.github/workflows/oracle.yml`:

```yaml
name: oracle
on: [push, workflow_dispatch]
jobs:
  nsview-geometry:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build and run probe
        run: |
          clang -framework Cocoa -fobjc-arc probes/nsview-geometry.m -o probe
          ./probe | tee probe-output.txt
      - uses: actions/upload-artifact@v4
        with:
          name: nsview-geometry-values
          path: probe-output.txt
```

- [ ] **Step 3: Push the oracle repo/branch and run it**

Create the repo (`gh repo create DTW-Thalion/gnustep-oracle --private --source . --push`) or push a scratch branch that never targets upstream. Trigger the workflow, wait for it, and download `probe-output.txt`:
```
gh run list --repo DTW-Thalion/gnustep-oracle --limit 1
gh run download --repo DTW-Thalion/gnustep-oracle <run-id> --name nsview-geometry-values --dir .
```
Expected: one `id = value` line per probe, e.g. `convertRect.windowless.inner_to_outer = {{60, 40}, {20, 20}}`.

- [ ] **Step 4: Record the values doc and commit (gnustep-audit)**

Write `docs/oracle/2026-07-19-nsview-geometry.md` as a table of `probe id | AppKit value`, verbatim from `probe-output.txt`. Then:
```
cd C:\Users\toddw\source\repos\gnustep-audit
git add docs/oracle/2026-07-19-nsview-geometry.md
git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "record macOS NSView geometry values"
```
Note in the doc which probes needed a window (windowed/nil cases) versus which are windowless — the suites use this to decide the skip guard.

**Note on completeness:** Tasks 2-6 enumerate the full case list each suite needs. Before writing those suites, extend `probes/nsview-geometry.m` with every enumerated case and re-run, so the values doc is complete. It is cheaper to add cases and re-run once than to make several macOS runs.

---

### Task 2: Consolidate and expand coordinate conversion → `convert.m`

**Files:**
- Create: `~/gnustep-reaudit/libs-gui/Tests/gui/NSView/convert.m`
- Delete (after folding): `~/gnustep-reaudit/libs-gui/Tests/gui/NSView/NSView_convertRect.m`, `~/gnustep-reaudit/libs-gui/Tests/gui/NSView/geometry.m`

**Interfaces:**
- Consumes: the values doc from Task 1 (`convert*.` probe ids).
- Produces: a green conversion suite (passing assertions only) and a divergence list appended to `docs/oracle/2026-07-19-nsview-geometry.md` under "Divergences".

**Case list to cover** (each with the value from the Task 1 doc): `convertPoint:toView:`/`fromView:`, `convertRect:toView:`/`fromView:`, `convertSize:toView:`/`fromView:`; for each: inner→outer and the reverse; windowless hierarchy; windowed hierarchy; through a flipped-view subclass; and to/from `nil` (window base coordinates, windowed only). Carry across every assertion currently in `NSView_convertRect.m` (re-verify each against the Task 1 value; if a carried assertion pins a value that disagrees with macOS, that is a divergence too).

- [ ] **Step 0: Create the coverage branch on the correct base** (see Preconditions)

Confirm #601's disposition, then branch:
```
wsl -d Ubuntu -- bash -lc 'cd ~/gnustep-reaudit/libs-gui && git fetch origin && git fetch myfork && git checkout -b tests/nsview-geometry-suite origin/master && ls Tests/gui/NSView/geometry.m Tests/gui/NSView/rendering.m 2>/dev/null && echo "601 MERGED (files present)" || echo "601 NOT merged -> rebase base onto origin/tests/nsview-geometry instead"'
```
If the files are absent (#601 not merged), instead: `git checkout -b tests/nsview-geometry-suite myfork/tests/nsview-geometry`. All Task 2-7 commits land on `tests/nsview-geometry-suite`.

- [ ] **Step 1: Read the existing file so no assertion is lost**

Run: `wsl -d Ubuntu -- bash -lc 'cat ~/gnustep-reaudit/libs-gui/Tests/gui/NSView/NSView_convertRect.m'`. List its assertions; each must have a counterpart in `convert.m` (or be a divergence).

- [ ] **Step 2: Write the suite**

Create `convert.m`. Windowless cases use no window; windowed / nil cases create a window and use the broadened skip guard. Structure (fill every case; the two shown are the pattern, expected values from the Task 1 doc):

```objc
#import "Testing.h"
#import <Foundation/NSGeometry.h>
#import <AppKit/NSApplication.h>
#import <AppKit/NSView.h>
#import <AppKit/NSWindow.h>

@interface FlippedView : NSView @end
@implementation FlippedView
- (BOOL) isFlipped { return YES; }
@end

int main(int argc, const char **argv)
{
  CREATE_AUTORELEASE_POOL(arp);
  START_SET("NSView convert")

  NS_DURING
    [NSApplication sharedApplication];
  NS_HANDLER
    if ([[localException name] isEqualToString: NSInternalInconsistencyException])
      SKIP("It looks like GNUstep backend is not yet installed")
  NS_ENDHANDLER

  /* windowless: display-independent */
  NSView *outer = AUTORELEASE([[NSView alloc] initWithFrame: NSMakeRect(0,0,200,200)]);
  NSView *inner = AUTORELEASE([[NSView alloc] initWithFrame: NSMakeRect(50,30,100,100)]);
  [outer addSubview: inner];

  NSPoint p = [inner convertPoint: NSMakePoint(10,10) toView: outer];
  PASS(NSEqualPoints(p, NSMakePoint(60,40)),   /* value from Task 1 doc */
    "convertPoint:toView: offsets by the subview origin");

  END_SET("NSView convert")

  /* windowed / nil cases: need a display */
  START_SET("NSView convert (windowed)")
  NSBitmapImageRep *unused = nil; (void)unused;
  NS_DURING
    {
      [NSApplication sharedApplication];
      NSWindow *w = AUTORELEASE([[NSWindow alloc] initWithContentRect: NSMakeRect(0,0,200,200)
        styleMask: NSWindowStyleMaskBorderless backing: NSBackingStoreBuffered defer: NO]);
      NSView *wOuter = [w contentView];
      NSView *wInner = AUTORELEASE([[NSView alloc] initWithFrame: NSMakeRect(50,30,100,100)]);
      [wOuter addSubview: wInner];
      NSRect r = [wInner convertRect: NSMakeRect(10,10,20,20) toView: wOuter];
      PASS(NSEqualRects(r, NSMakeRect(60,40,20,20)),   /* value from Task 1 doc */
        "convertRect:toView: offsets by the subview origin (windowed)");
    }
  NS_HANDLER
    if ([[localException name] isEqualToString: NSInternalInconsistencyException]
        || [[localException name] isEqualToString: @"NSWindowServerCommunicationException"])
      SKIP("No display available")
  NS_ENDHANDLER
  END_SET("NSView convert (windowed)")

  DESTROY(arp);
  return 0;
}
```

- [ ] **Step 3: Run it and route pass/fail**

Run with a display:
```
wsl -d Ubuntu -- bash -lc 'cd ~/gnustep-reaudit/libs-gui/Tests && . /usr/local/share/GNUstep/Makefiles/GNUstep.sh && export LD_LIBRARY_PATH=/home/toddw/gnustep-reaudit/libs-gui/Source/obj:/usr/local/lib ADDITIONAL_LDFLAGS=-L/usr/local/lib && gnustep-tests gui/NSView/convert.m 2>&1 | grep -iE "passed|failed|skipped"'
```
Every assertion that FAILS is a confirmed divergence (its macOS value disagrees with GNUstep). Remove those assertions from `convert.m` and append them to the "Divergences" section of the Task 1 doc as `probe id | macOS value | GNUstep value | source method`. `convert.m` must end GREEN (all remaining PASS). The expected first divergence: `convertRect` windowless no-ops (`_window==nil` guard).

- [ ] **Step 4: Verify windowless cases are display-independent**

Run genuinely headless (windowless START_SET must still pass; windowed START_SET must SKIP, not fail):
```
wsl -d Ubuntu -- bash -lc 'cd ~/gnustep-reaudit/libs-gui/Tests && . /usr/local/share/GNUstep/Makefiles/GNUstep.sh && export LD_LIBRARY_PATH=/home/toddw/gnustep-reaudit/libs-gui/Source/obj:/usr/local/lib ADDITIONAL_LDFLAGS=-L/usr/local/lib && DISPLAY=:99 XDG_RUNTIME_DIR=$(mktemp -d) gnustep-tests gui/NSView/convert.m 2>&1 | grep -iE "passed|failed|skipped"'
```
Expected: windowless assertions Passed; windowed set Skipped; 0 Failed.

- [ ] **Step 5: Delete the folded files and commit**

```
wsl -d Ubuntu -- bash -lc 'cd ~/gnustep-reaudit/libs-gui && git rm Tests/gui/NSView/NSView_convertRect.m Tests/gui/NSView/geometry.m && git add Tests/gui/NSView/convert.m && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "tests: consolidate NSView coordinate conversion tests"'
```

---

### Task 3: Consolidate and expand frame/bounds → `frameBounds.m`

**Files:**
- Create: `~/gnustep-reaudit/libs-gui/Tests/gui/NSView/frameBounds.m`
- Delete (after folding): `NSView_frame_bounds.m`, `NSView_bounds_scale.m`, `NSView_setFrameSize_zero.m`

**Interfaces:**
- Consumes: Task 1 values (`frame*`, `bounds*`, `centerScan*` ids).
- Produces: a green frame/bounds suite; divergences appended to the Task 1 doc.

**Case list:** `setFrame:`/`setFrameOrigin:`/`setFrameSize:` and the resulting `bounds`; `setBounds:`/`setBoundsOrigin:`/`setBoundsSize:` and the resulting `frame`/coordinate scale; frame↔bounds when they differ in size (scale); `centerScanRect:`; backing-aligned rect; the zero-dimension case carried from `NSView_setFrameSize_zero.m` (rotated view keeps finite bounds across zero width). Carry every assertion from the three deleted files.

- [ ] **Step 1: Read the three existing files** — `wsl -d Ubuntu -- bash -lc 'cd ~/gnustep-reaudit/libs-gui/Tests/gui/NSView && cat NSView_frame_bounds.m NSView_bounds_scale.m NSView_setFrameSize_zero.m'`. Enumerate assertions to carry.
- [ ] **Step 2: Write `frameBounds.m`** using the same START_SET / skip-guard structure as Task 2 (windowless where possible; these are mostly display-independent). Expected values from the Task 1 doc.
- [ ] **Step 3: Run with a display**, route failures to the Divergences list, keep the file green (command as Task 2 Step 3 with `frameBounds.m`).
- [ ] **Step 4: Run genuinely headless** (Task 2 Step 4 command with `frameBounds.m`); windowless assertions pass, any windowed set skips.
- [ ] **Step 5: Delete folded files and commit**
```
wsl -d Ubuntu -- bash -lc 'cd ~/gnustep-reaudit/libs-gui && git rm Tests/gui/NSView/NSView_frame_bounds.m Tests/gui/NSView/NSView_bounds_scale.m Tests/gui/NSView/NSView_setFrameSize_zero.m && git add Tests/gui/NSView/frameBounds.m && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "tests: consolidate NSView frame and bounds tests"'
```

---

### Task 4: Consolidate and expand rotation → `rotation.m`

**Files:**
- Create: `~/gnustep-reaudit/libs-gui/Tests/gui/NSView/rotation.m`
- Delete (after folding): `NSView_frame_rotation.m`

**Interfaces:**
- Consumes: Task 1 values (`rotation*` ids).
- Produces: a green rotation suite; divergences appended.

**Case list:** `setFrameRotation:`/`frameRotation`; `setBoundsRotation:`/`boundsRotation`; `rotateByAngle:`; a non-axis-aligned rotation and its effect on a converted point/rect; carry every assertion from `NSView_frame_rotation.m`.

- [ ] **Step 1: Read `NSView_frame_rotation.m`** and enumerate assertions to carry.
- [ ] **Step 2: Write `rotation.m`** (same structure; rotation math is windowless/display-independent). Values from the Task 1 doc.
- [ ] **Step 3: Run with a display**, route failures to Divergences, keep green.
- [ ] **Step 4: Run genuinely headless**; assertions pass display-less.
- [ ] **Step 5: Delete folded file and commit**
```
wsl -d Ubuntu -- bash -lc 'cd ~/gnustep-reaudit/libs-gui && git rm Tests/gui/NSView/NSView_frame_rotation.m && git add Tests/gui/NSView/rotation.m && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "tests: consolidate NSView rotation tests"'
```

---

### Task 5: Consolidate and expand autoresize → `autoresize.m`

**Files:**
- Create: `~/gnustep-reaudit/libs-gui/Tests/gui/NSView/autoresize.m`
- Delete (after folding): `NSView_autoresize_and_rounding.m`

**Interfaces:**
- Consumes: Task 1 values (`autoresize*` ids).
- Produces: a green autoresize suite; divergences appended.

**Case list:** for a subview in a 100x100 superview resized to a fixed larger size, the resulting subview frame under each of the meaningful `autoresizingMask` combinations (none; width-sizable; height-sizable; min/max margin flexible; combinations). Add the rounding case carried from `NSView_autoresize_and_rounding.m`. Autoresize is triggered by `setFrameSize:` on the superview (`resizeSubviewsWithOldSize:` / `setAutoresizesSubviews:YES`).

- [ ] **Step 1: Read `NSView_autoresize_and_rounding.m`** and enumerate assertions to carry.
- [ ] **Step 2: Write `autoresize.m`** (windowless; display-independent). Values from the Task 1 doc, one probe per mask combination.
- [ ] **Step 3: Run with a display**, route failures to Divergences, keep green.
- [ ] **Step 4: Run genuinely headless**; passes display-less.
- [ ] **Step 5: Delete folded file and commit**
```
wsl -d Ubuntu -- bash -lc 'cd ~/gnustep-reaudit/libs-gui && git rm Tests/gui/NSView/NSView_autoresize_and_rounding.m && git add Tests/gui/NSView/autoresize.m && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "tests: consolidate NSView autoresize tests"'
```

---

### Task 6: Consolidate and expand visibility/scroll → `visibleClip.m`

**Files:**
- Create: `~/gnustep-reaudit/libs-gui/Tests/gui/NSView/visibleClip.m`
- Delete (after folding): `NSView_visibleRect.m`, `scrollRectToVisible.m`

**Interfaces:**
- Consumes: Task 1 values (`visibleRect*`, `scroll*` ids).
- Produces: a green visibility suite; divergences appended.

**Case list:** `visibleRect` of a fully-visible view, a partially-clipped subview, and a nested subview under a smaller superview; `scrollRectToVisible:` effect where a clip view exists. Some of these need a window/clip context — use the broadened skip guard for those. Carry every assertion from both deleted files.

- [ ] **Step 1: Read both existing files** and enumerate assertions to carry.
- [ ] **Step 2: Write `visibleClip.m`** (windowless where the geometry allows; windowed/clip cases use the broadened skip guard). Values from the Task 1 doc.
- [ ] **Step 3: Run with a display**, route failures to Divergences, keep green.
- [ ] **Step 4: Run genuinely headless**; windowless pass, windowed skip.
- [ ] **Step 5: Delete folded files and commit**
```
wsl -d Ubuntu -- bash -lc 'cd ~/gnustep-reaudit/libs-gui && git rm Tests/gui/NSView/NSView_visibleRect.m Tests/gui/NSView/scrollRectToVisible.m && git add Tests/gui/NSView/visibleClip.m && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "tests: consolidate NSView visibility tests"'
```

---

### Task 7: Finalize the consolidation and open the coverage PR

**Files:**
- Modify if present: `~/gnustep-reaudit/libs-gui/Tests/gui/NSView/GNUmakefile` / `TestInfo` (only if they enumerate test files explicitly; the GNUstep test runner discovers `.m` files, so usually no change).

**Interfaces:**
- Consumes: Tasks 2-6 suites.
- Produces: the green coverage PR.

- [ ] **Step 1: Confirm the old files are gone and only the new suites remain**

Run: `wsl -d Ubuntu -- bash -lc 'ls ~/gnustep-reaudit/libs-gui/Tests/gui/NSView/'`. Expected: `convert.m frameBounds.m rotation.m autoresize.m visibleClip.m rendering.m TestInfo` (plus `GNUmakefile`/`obj`); none of the eight deleted `NSView_*.m`/`scrollRectToVisible.m`/`geometry.m`.

- [ ] **Step 2: Run the whole NSView directory with a display**

```
wsl -d Ubuntu -- bash -lc 'cd ~/gnustep-reaudit/libs-gui/Tests && . /usr/local/share/GNUstep/Makefiles/GNUstep.sh && export LD_LIBRARY_PATH=/home/toddw/gnustep-reaudit/libs-gui/Source/obj:/usr/local/lib ADDITIONAL_LDFLAGS=-L/usr/local/lib && gnustep-tests gui/NSView 2>&1 | tail -8'
```
Expected: all Passed, 0 Failed, 0 unexpected Skipped (window-dependent sets may skip only if run display-less; with a display they pass). If any Failed, it is a divergence that leaked into the coverage suite — move it to the Divergences list.

- [ ] **Step 3: Push the branch and open the coverage PR**

```
"/c/Program Files/Git/bin/git.exe" -C "//wsl.localhost/Ubuntu/home/toddw/gnustep-reaudit/libs-gui" push myfork tests/nsview-geometry-suite
```
Open the PR against `gnustep/libs-gui` base `master`, head `DTW-Thalion:tests/nsview-geometry-suite`, title `tests: rework NSView geometry tests`. Body (terse, factual, per discipline): state that the scattered NSView geometry tests are consolidated into topic suites and expanded, and map each removed file to its new home (convert.m ← NSView_convertRect.m + geometry.m; frameBounds.m ← NSView_frame_bounds.m + NSView_bounds_scale.m + NSView_setFrameSize_zero.m; rotation.m ← NSView_frame_rotation.m; autoresize.m ← NSView_autoresize_and_rounding.m; visibleClip.m ← NSView_visibleRect.m + scrollRectToVisible.m). No mention of internal process terms. Draft the body for Todd's review before posting.

- [ ] **Step 4: Discipline audit on the PR**

Before and after opening: `git diff origin/master..tests/nsview-geometry-suite | grep -iE "co-authored|claude|generated with|🤖|anthropic|RB-|TS-|PF-|BUG-|oracle|campaign"` must be empty; verify the live PR body the same way.

---

### Task 8: Fix PR — NSView convertRect ignores the hierarchy without a window

Only if Task 2 confirmed the divergence against macOS (AppKit transforms windowless; GNUstep no-ops). If macOS also no-ops, there is no bug — record that and skip this task.

**Files:**
- Modify: `~/gnustep-reaudit/libs-gui/Source/NSView.m` (the `convertRect:toView:` and `convertRect:fromView:` `_window == nil` guard).
- Create: `~/gnustep-reaudit/libs-gui/Tests/gui/NSView/convert_windowless_rect.m` (the fail-before/pass-after test).

**Interfaces:**
- Consumes: the divergence record and macOS value from Task 1/2.
- Produces: a fix branch `fix/nsview-convertrect-windowless` off `origin/master` and its PR.

- [ ] **Step 1: Branch off master** — `wsl -d Ubuntu -- bash -lc 'cd ~/gnustep-reaudit/libs-gui && git checkout origin/master -b fix/nsview-convertrect-windowless'`.
- [ ] **Step 2: Write the failing test** `convert_windowless_rect.m`: windowless `outer`/`inner`, assert `convertRect:` inner→outer equals the macOS value (same shape as `convert.m`'s windowless point case). Run it: it must FAIL (GNUstep returns the input unchanged).
- [ ] **Step 3: Read the guard and fix it** — inspect `Source/NSView.m` `convertRect:toView:`/`fromView:`. Make windowless conversion apply the hierarchy transform (as `convertPoint:` does) rather than returning `aRect` when `_window == nil`, without changing the cross-window / screen behaviour. Add only a short hazard note plus a pointer to the test, no change-describing comment.
- [ ] **Step 4: Run the test — must PASS**, and run the whole `gui/NSView` directory to confirm no regression:
```
wsl -d Ubuntu -- bash -lc 'cd ~/gnustep-reaudit/libs-gui && . /usr/local/share/GNUstep/Makefiles/GNUstep.sh && make -j$(nproc) && cd Tests && export LD_LIBRARY_PATH=/home/toddw/gnustep-reaudit/libs-gui/Source/obj:/usr/local/lib ADDITIONAL_LDFLAGS=-L/usr/local/lib && gnustep-tests gui/NSView 2>&1 | tail -8'
```
- [ ] **Step 5: Commit, push, open the fix PR** — commit `Fix: NSView convertRect:toView: ignores the view hierarchy without a window` (author Todd White), push `myfork fix/nsview-convertrect-windowless`, open PR against `gnustep/libs-gui` master. Body: describe the observed behaviour, the macOS behaviour it should match, and that the test fails before and passes after. Discipline audit as Task 7 Step 4.

---

### Task 9: Fix PRs for any further divergences the sweep surfaced

For each entry remaining in the Divergences list (Task 1 doc), repeat the Task 8 pattern on its own `fix/nsview-<topic>` branch: a fail-before/pass-after test asserting the macOS value, the minimal `Source/NSView.m` change, whole-directory regression run, and a separate `Fix: …` PR. Keep each PR to one divergence so the maintainer can review them independently. If the list is empty, this task is a no-op.

- [ ] **Step 1:** List the Divergences entries; create one checklist item per entry naming its source method and branch.
- [ ] **Step 2:** For each, execute the Task 8 steps (failing test → minimal fix → regression run → separate PR).

---

## Definition of Done

- The macOS NSView geometry values are recorded in `docs/oracle/2026-07-19-nsview-geometry.md`, and the reusable oracle repo/workflow exists for later classes.
- The eight scattered `NSView_*.m`/`scrollRectToVisible.m`/`geometry.m` files are replaced by `convert.m`, `frameBounds.m`, `rotation.m`, `autoresize.m`, `visibleClip.m` with no lost assertions and materially broader coverage; `rendering.m` unchanged.
- The whole `gui/NSView` directory runs green with a display; windowless suites also pass genuinely display-less; window-dependent sets skip cleanly display-less.
- The coverage PR `tests: rework NSView geometry tests` is open and discipline-clean, with a file-to-file mapping in its body.
- The convertRect-without-window question is resolved against AppKit; each confirmed divergence ships as its own `Fix:` PR with a fail-before/pass-after test.
- Every upstream artifact follows the contribution discipline.
