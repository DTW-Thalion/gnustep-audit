# libs-gui Phase 1 — NSView Geometry Audit and Suite Consolidation — Design

Date: 2026-07-19
Status: approved (design); pending spec review
Owner: Todd White
Parent spec: `2026-07-18-libs-gui-heavy-class-testing-design.md`
Harness: Phase 0b delivered the backend-in-CI lane (gnustep/libs-gui issue #602,
branch `ci/headless-gui-tests`) and the reference test patterns (gnustep/libs-gui
PR #601: `Tests/gui/NSView/geometry.m`, `rendering.m`).

## Scope

The first Phase 1 increment: a comprehensive audit and consolidated test suite of
the NSView geometry/coordinate surface, chosen as the base of the dependency
spine and the highest bug-yield vein. It starts from a live lead found during
Phase 0b: `-[NSView convertRect:toView:]` returns its argument unchanged when the
view has no window (raw `_window == nil` guard in `Source/NSView.m`), which
`convertPoint:toView:` does not do. Whether that diverges from AppKit is the
first thing the oracle settles.

NSView geometry already has scattered coverage
(`NSView_convertRect.m`, `NSView_frame_bounds.m`, `NSView_frame_rotation.m`,
`NSView_bounds_scale.m`, `NSView_autoresize_and_rounding.m`,
`NSView_setFrameSize_zero.m`, `NSView_visibleRect.m`, `scrollRectToVisible.m`,
plus the PR #601 `geometry.m`). This increment consolidates those into clean
topic-grouped suites, preserving every existing assertion, and expands them to
the full geometry surface. NSResponder, NSWindow, and NSControl are untouched
here and remain later Phase 1 increments.

## Corrected mechanism (supersedes the parent spec's headless premise)

The parent spec states headless-first with Xvfb as a contingency, based on the
Phase 0a spike. Phase 0b's CI run on a real display-less runner corrected this:
`[NSApplication sharedApplication]` succeeds with no display, but any operation
that reaches the window server (creating a window, querying the screen list)
raises `NSWindowServerCommunicationException`. The Phase 0a spike passed only
because WSLg keeps a reachable display even with `DISPLAY`/`WAYLAND_DISPLAY`
unset. So:

- Xvfb is required for any test that touches the window server, not a
  contingency. The #602 CI lane runs the suite under `xvfb-run`.
- Only windowless view math is genuinely display-independent, and only through
  APIs without a window guard (`convertPoint:` yes, `convertRect:` no in the
  current code).
- To simulate display-less locally: `DISPLAY=:99` plus an empty
  `XDG_RUNTIME_DIR`, not `env -u DISPLAY` (which false-passes under WSLg).

## Workflow

1. Oracle sweep. One macOS GitHub Actions run probes the NSView geometry surface
   with fixed inputs and records ground-truth values. This is the gate; no
   expected value is assumed.
2. Classify. Each probed behaviour where GNUstep matches AppKit becomes a passing
   assertion in the green coverage suite. Each divergence becomes a fix PR.
3. Consolidate and expand. Rewrite the scattered geometry tests into topic
   suites, carrying every existing assertion across before deleting the old file,
   and add the swept coverage.
4. Ship. A green `tests:` coverage PR (consolidation plus passing sweep), then
   separate `Fix:` PR(s), each with a fail-before/pass-after test.

## Oracle probe scope

Coordinate conversion: `convertPoint:toView:`/`fromView:`,
`convertRect:toView:`/`fromView:`, `convertSize:toView:`/`fromView:`; windowed vs
windowless hierarchies; conversion through a flipped view (isFlipped subclass);
conversion to and from `nil` (window base coordinates). Frame and bounds:
`setFrame:`, `setFrameOrigin:`, `setFrameSize:`, `setBounds:`,
`setBoundsOrigin:`, `setBoundsSize:`, frame/bounds relationship,
`centerScanRect:`, backing-aligned rects. Rotation: `frameRotation`,
`boundsRotation`, `rotateByAngle:`, non-axis-aligned bounds and their effect on
conversion. Autoresize: the full `autoresizingMask` matrix mapped to subview
frames on superview resize. Visibility: `visibleRect` under clipping and
nesting, `scrollRectToVisible:`.

Excluded from the Apple audit (parent spec): pixel fidelity and
font-metric-derived sizes.

## Suite organization

Replace the scattered files with topic-grouped suites under `Tests/gui/NSView/`:

- `convert.m` — absorbs `NSView_convertRect.m` and PR #601 `geometry.m`; adds
  point/size/rect x to/from x windowed/windowless/flipped, and conversion to/from
  a nil view.
- `frameBounds.m` — absorbs `NSView_frame_bounds.m`, `NSView_bounds_scale.m`,
  `NSView_setFrameSize_zero.m`; adds setBounds origin/size, centerScanRect,
  backing alignment.
- `rotation.m` — absorbs `NSView_frame_rotation.m`; adds boundsRotation,
  rotateByAngle, non-axis-aligned bounds.
- `autoresize.m` — absorbs `NSView_autoresize_and_rounding.m`; adds the full mask
  matrix to subview frames.
- `visibleClip.m` — absorbs `NSView_visibleRect.m` and `scrollRectToVisible.m`;
  adds visibleRect under clipping and nesting.

`rendering.m` (Tier C, PR #601) is unchanged. Every old file's assertions are
carried into its target suite before that old file is deleted; no coverage is
lost.

## Display handling

Windowless tests (convertPoint, frame/bounds, autoresize, rotation math) are
display-independent and run under the #602 lane and locally. Tests that need a
window (convertRect/convertPoint to/from nil for window-base coordinates, screen
conversion) carry the skip guard broadened to also catch
`NSWindowServerCommunicationException`, so they skip cleanly where there is no
display, matching `rendering.m`. The coverage suite therefore lands cleanly in
upstream CI now (window-dependent tests skip until the #602 lane exists) and is
fully enforced once the lane lands; it does not hard-depend on #602.

## PR sequence

1. `tests: rework NSView geometry tests` — the consolidation plus the passing
   sweep; green. The body maps each deleted file to its new home so the deletions
   are justified to the maintainer.
2. `Fix: NSView convertRect:toView: ignores the view hierarchy without a window`
   and any further divergences the oracle exposes — each a small fix PR with a
   fail-before/pass-after test.

Small and reviewable, given the maintainer's limited review capacity.

## Contribution discipline (binds every implementer)

Any artifact that reaches an upstream GNUstep repository — test or source code,
code comments, commit messages, PR titles and bodies, issue text — must:

- carry no AI/Claude attribution in any form: no `Co-Authored-By`, no robot
  emoji, no "Generated with"; commits authored as
  `Todd White <todd.white@thalion.global>` with no trailers;
- read as Todd White's own writing: factual and terse, no LLM style tells (no
  bold section headers, pervasive bullet lists, rule-of-three, em-dash drama,
  signposting, or closing offers);
- contain no internal tracking identifiers (RB-, TS-, PF-, BUG-) and none of our
  private process vocabulary ("coverage-as-audit", "oracle", "the campaign");
- add no change-describing comments in source; a fix site gets a short hazard
  note and a pointer to its test, nothing more.

Draft any substantive upstream prose for review before posting.

## Risks

- Oracle access: the macOS runner probe must compile against `-framework Cocoa`
  and produce machine-readable values; a fresh singleton or environment-dependent
  answer can mislead (see the macOS oracle reference). Probes must discriminate
  the specific hypothesis.
- Consolidation regressions: rewriting existing tests risks dropping an
  assertion. The plan verifies the new suite runs and that each old assertion has
  a counterpart before deleting a file.
- Maintainer caution on deletions: a PR that removes existing tests needs a clear
  file-to-file mapping in its body; keep the consolidation reviewable.
- Divergence that is intended GNUstep behaviour: not every mismatch is a bug.
  Where GNUstep deliberately differs, record it and do not file a fix.

## Success criteria

- The macOS oracle values for the NSView geometry surface are captured and
  recorded.
- A green consolidated NSView geometry coverage suite replaces the scattered
  files with no lost assertions and materially broader coverage.
- The convertRect-without-window question is resolved against AppKit, and any
  confirmed divergence ships as a fix PR with a fail-before/pass-after test.
