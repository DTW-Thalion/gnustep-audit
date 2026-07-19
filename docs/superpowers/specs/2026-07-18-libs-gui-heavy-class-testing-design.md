# libs-gui Heavy-Class Testing Strategy — Design

Date: 2026-07-18
Status: approved (direction); pending spec review
Owner: Todd White

## Problem

The coverage-as-audit technique — probe a class's behaviour on a macOS runner
(the "oracle"), diff GNUstep's values against AppKit, pin the correct behaviour
in a test, file a green coverage/test PR plus separate fix PR(s) — has worked
well for **value / cell / model classes** (NSToolbarItem, NSTabViewItem,
NSPathControl, NSAppearance, NSDockTile, NSTextTableBlock, cells). Those classes
expose behaviour as *return values*: getters, setter round-trips, defaults, enum
values, coding keys, copy semantics, type encodings. That is exactly what an
oracle can A/B, and it has found real bugs (wrong enum values, wrong selector
names, copy crashes, an over-release core dump).

The remaining untested classes are the ~130 heavyweight **view / window**
classes (NSView, NSWindow, NSTableView, NSScrollView, NSTextView, NSMatrix,
NSBrowser, NSOutlineView, …). Their behaviour is dominated by rendering,
geometry/layout, event handling, first-responder, and backend interaction —
none of which is a return value you can diff against Apple by design (GNUstep
pixels differ from AppKit pixels on purpose). The value-oracle A/B technique does
not, by itself, reach these classes.

## Goal and mandate

- **Same audit mission**: find where GNUstep's heavy classes diverge from AppKit
  behaviour and file fixes. Bug-yield is the point, not a coverage percentage.
- These are the **core working classes of every GUI app**, so they get **full,
  tiered test suites**, not just the cheap-to-oracle slice.
- **Infra-first**: build the backend-in-CI harness before class suites, so the
  behavioural and rendering tiers are CI-enforced from the first PR.
- **Order = dependency spine outward**: NSResponder → NSView → NSWindow →
  NSControl, then containers, data views, text, controls.
- **Not scoped to the Thalion monitoring UI.** This is a standalone, thorough
  job on the core classes; the monitoring UI benefits as a side effect and must
  not narrow the scope.

## Contribution discipline (binds every phase and every implementer)

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

Draft any substantive upstream prose for review before posting. These planning
documents are internal and may stay structured; nothing from them ships upstream
unfiltered. This section is copied verbatim into the Global Constraints of every
plan derived from this spec.

## Testable-surface model — three tiers per class

A "heavy" class is not uniformly untestable. Its API splits into surfaces with
very different oracle-ability, and each class gets a suite covering all three:

- **Tier A — Apple audit.** Geometry/coordinate math, state/model/flags, coding
  and copy. Deterministic values computable on both platforms → diff against the
  macOS oracle. fail-before/pass-after when GNUstep diverges → drives fix PRs.
  Runs green in CI. This is coverage-as-audit, just embedded in bigger classes;
  the **geometry/coordinate-math surface is the largest under-tested, high
  bug-yield vein** (e.g. `convertRect:toView:`, autoresize → subview frames,
  `rectOfRow:`, flipped-coordinate handling; #550's hardcoded
  `NSLayoutAttributeLeft` was a taste of it).
- **Tier B — behavioural.** Real window/backend behaviour: layout passes,
  window-relative coordinate conversion, hit-testing, tracking. Needs a live
  backend. Most of it is deterministic and runs headless; the true event-loop /
  mouse-tracking minority needs event injection under Xvfb.
- **Tier C — render regression.** Offscreen render → assert on the **drawing
  operation stream**, GNUstep-vs-itself, to catch `drawRect:` regressions. Not
  an Apple pixel diff — a regression lock.

Explicitly **out of Apple-audit scope**: pixel fidelity and font-metric-derived
sizes (row heights from font ascent/descent, cell sizes) — these differ across
platforms and environments by design.

## Mechanism decisions

1. **Headless-first backend; Xvfb+x11 only for true event tests.** Run Tiers A,
   C, and the windowless part of B against an in-memory backend with no display
   (cairo image surface; views render offscreen via `lockFocus` /
   `NSBitmapImageRep`). Deterministic, fast, CI-green. Stand up an Xvfb+x11 lane
   (as libs-back did for its x11 tests) **only** for the mouse-tracking /
   event-loop minority, and quarantine its flakiness away from the gating tiers.

2. **Render regression via draw-op stream, not pixel bitmaps.** Render the view
   through the **GSStreamContext (PostScript/DPS) backend** and assert on the
   drawing-operation stream ("fill rect X colour Y, stroke path Z"). Deterministic,
   font-robust for shapes, needs no display, human-diffable, and partially
   doubles as an audit of *what* is drawn (the logic, not the pixels). Keep
   tolerant golden-bitmaps only for the few cases where actual pixels are the
   point. (Precedent: the libs-back GSStreamContext PostScript backend tests.)

3. **Phase-0 spike gates everything.** The whole architecture rests on one
   unconfirmed assumption: **can GNUstep's backend initialise and render
   offscreen in CI with no display connection?** If yes, headless-first works as
   described; if the backend refuses to init without an X connection, even
   offscreen rendering needs Xvfb and the architecture shifts. So Phase 0's first
   deliverable is a small spike proving (a) a libs-gui test can bring up a
   backend headless and render a known view offscreen, and (b) the draw-op stream
   is stable run-to-run and across environments. This follows the standing
   "prove the phase-0 spec before wiring breaks" discipline and de-risks the
   program cheaply.

## Phases

- **Phase 0 — Harness (spike-gated).**
  1. Spike: headless backend init + offscreen render + stable draw-op stream.
  2. Build shared test infra: a headless render/draw-op-capture helper, the
     draw-op-stream comparison, and the Xvfb+x11 event lane.
  3. Get Fred's buy-in on the approach and the new CI lane **before** building
     class suites on top of it (he added the libs-back Xvfb lane, so he is
     receptive). Deliverable: a proposed CI-lane + shared-test-infra PR.
- **Phase 1 — Dependency spine.** NSResponder → NSView → NSWindow → NSControl,
  three-tier suites each. Highest leverage: bugs in the base propagate to
  everything.
- **Phase 2+ — Outward.** Containers (NSScrollView, NSClipView, NSSplitView,
  NSStackView, NSBox, NSTabView) → data views (NSTableView, NSOutlineView,
  NSMatrix, NSBrowser, NSCollectionView) → text (NSText, NSTextView,
  NSTextField, NSLayoutManager, NSTextStorage) → controls.

## Per-class workflow (extends coverage-as-audit)

1. Oracle the class surface on the macOS runner: method-surface / type-encoding,
   geometry probes (fixed inputs → computed frames/rects/points), coding keys,
   recorder-delegate for callback order.
2. Write the three-tier suite (A/B/C) for the class.
3. Package per existing conventions: a green **coverage/test PR** separate from
   **fix PR(s)**; titles `tests: add NSXxx tests` and `Fix: …`; commits authored
   as Todd White, tell-clean, no AI attribution / no internal IDs; backend SKIP
   guard on any test that reaches `sharedApplication` and cannot run headless.
4. Every fix ships with a fail-before/pass-after test.

## Constraints and risks

- **Gating unknown — CORRECTED 2026-07-19 by the real CI run:** the Phase 0a
  spike conclusion above was a WSLg artifact. On a genuinely display-less runner
  the suite runs (0 skip) but any window-server operation (window creation, screen
  list) raises `NSWindowServerCommunicationException`. Xvfb is REQUIRED for
  window-touching tests, not a contingency; only windowless view math is
  display-independent, and only through APIs without a window guard
  (`convertPoint:` yes, `convertRect:` no). The #602 CI lane runs under
  `xvfb-run`. See `docs/spikes/2026-07-18-libs-gui-headless-render.md` (0b
  sections) and `docs/superpowers/specs/2026-07-19-libs-gui-nsview-geometry-audit-design.md`.
- **Font-metric variance** across environments → exclude font-derived sizes from
  the Apple audit; the draw-op stream avoids pixel/font fragility for shapes.
- **Fred's review capacity** is limited (he is flooded). Keep PRs small and
  reviewable; secure his buy-in on the harness before scaling out suites.
- **CI flakiness**: quarantine the Xvfb/event lane; the headless deterministic
  tiers are the merge gate.
- **Backend bundle nuance**: the runtime loads the user-domain back bundle — the
  harness must target the intended backend explicitly.
- **Timeline**: the Thalion team rolls off UI work after ~Aug 1, but scope is not
  Thalion-bound; this proceeds as a standalone effort.

## Open questions (resolve during spec review / Phase 0)

- Exact headless mechanism — RESOLVED: cairo in-memory surfaces; no display and
  no dedicated headless bundle are needed.
- Tier C capture format — REVISED: the `dataWithEPSInsideRect:` op-stream is dead
  (delegates to `NSPrintOperation runOperation`, which hangs display-less). The
  harness plan first probes a `GSStreamContext`/`NSDPSContext`-on-memory-stream
  capture that bypasses the print pipeline; failing that, offscreen-bitmap
  regression scoped to non-text (solid/shape) regions, with Tier A geometry
  carrying text-layout correctness.
- Whether Fred wants the new CI lane in gnustep/libs-gui CI itself or as an
  opt-in job.

## Success criteria

- **Phase 0**: headless offscreen render and a stable draw-op stream proven in
  CI; shared harness merged or Fred-approved.
- **Ongoing**: each core class has a three-tier suite; the audit continues to
  surface real AppKit divergences that ship as fixes (sustained bug-yield).
