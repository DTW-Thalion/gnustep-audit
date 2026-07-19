# NSView geometry — macOS AppKit values (2026-07-19)

Source: `DTW-Thalion/gnustep-oracle`, `probes/nsview-geometry.m`, workflow run
[29691253068](https://github.com/DTW-Thalion/gnustep-oracle/actions/runs/29691253068)
(macOS runner, `clang -framework Cocoa -fobjc-arc`). Values below are verbatim
from the runner's `probe-output.txt`; none have been edited or "corrected".

All fixed inputs: `outer` frame `(0,0,200,200)`, `inner` frame `(50,30,100,100)`
as a subview of `outer`, unless noted otherwise per probe. 78 probes captured,
0 `ERROR:` lines.

## convert

Windowless probes use a plain `NSView` hierarchy with no window. Windowed
probes create an `NSWindowStyleMaskBorderless` window and use its
`contentView`; the window is never ordered front / made key. `nil`-view
probes convert to/from the window's base coordinate system.

| probe id | AppKit value |
|---|---|
| convertPoint.windowless.toView.inner_to_outer | `{60, 40}` |
| convertPoint.windowless.toView.outer_to_inner | `{-40, -20}` |
| convertPoint.windowless.fromView.inner_to_outer | `{60, 40}` |
| convertPoint.windowless.fromView.outer_to_inner | `{-40, -20}` |
| convertRect.windowless.toView.inner_to_outer | `{{60, 40}, {20, 20}}` |
| convertRect.windowless.toView.outer_to_inner | `{{-40, -20}, {20, 20}}` |
| convertRect.windowless.fromView.inner_to_outer | `{{60, 40}, {20, 20}}` |
| convertRect.windowless.fromView.outer_to_inner | `{{-40, -20}, {20, 20}}` |
| convertSize.windowless.toView.inner_to_outer | `{20, 20}` |
| convertSize.windowless.toView.outer_to_inner | `{20, 20}` |
| convertSize.windowless.fromView.inner_to_outer | `{20, 20}` |
| convertSize.windowless.fromView.outer_to_inner | `{20, 20}` |
| convertPoint.flipped.toView.inner_to_outer | `{60, 120}` |
| convertPoint.flipped.toView.outer_to_inner | `{-40, 120}` |
| convertRect.flipped.toView.inner_to_outer | `{{60, 100}, {20, 20}}` |
| convertRect.flipped.toView.outer_to_inner | `{{-40, 100}, {20, 20}}` |
| convertSize.flipped.toView.inner_to_outer | `{20, 20}` |
| convertPoint.windowed.toView.inner_to_outer | `{60, 40}` |
| convertPoint.windowed.toView.outer_to_inner | `{-40, -20}` |
| convertPoint.windowed.fromView.inner_to_outer | `{60, 40}` |
| convertPoint.windowed.fromView.outer_to_inner | `{-40, -20}` |
| convertRect.windowed.toView.inner_to_outer | `{{60, 40}, {20, 20}}` |
| convertRect.windowed.toView.outer_to_inner | `{{-40, -20}, {20, 20}}` |
| convertRect.windowed.fromView.inner_to_outer | `{{60, 40}, {20, 20}}` |
| convertRect.windowed.fromView.outer_to_inner | `{{-40, -20}, {20, 20}}` |
| convertSize.windowed.toView.inner_to_outer | `{20, 20}` |
| convertSize.windowed.toView.outer_to_inner | `{20, 20}` |
| convertPoint.windowed.toView.inner_to_nil | `{60, 40}` |
| convertPoint.windowed.fromView.nil_to_inner | `{10, 10}` |
| convertRect.windowed.toView.inner_to_nil | `{{60, 40}, {20, 20}}` |
| convertRect.windowed.fromView.nil_to_inner | `{{10, 10}, {20, 20}}` |
| convertSize.windowed.toView.inner_to_nil | `{20, 20}` |
| convertSize.windowed.fromView.nil_to_inner | `{20, 20}` |

**Seed-divergence question, settled:** `convertRect.windowless.toView.inner_to_outer`
= `{{60, 40}, {20, 20}}`. AppKit transforms the rect through the windowless
hierarchy exactly as `convertPoint:`/`convertSize:` do (input rect
`(10,10,20,20)`, subview origin `(50,30)` → `(60,40,20,20)`). It does **not**
no-op to `{{10, 10}, {20, 20}}`. If GNUstep's `convertRect:toView:`/`fromView:`
returns the untransformed rect when `_window == nil`, that is a confirmed
divergence from AppKit (Task 8 in the plan targets exactly this).

## frameBounds

All windowless; a fresh view is created per probe (`initWithFrame:
(0,0,100,100)` unless noted).

| probe id | AppKit value |
|---|---|
| frameBounds.setFrame.frame (setFrame:(10,20,50,60)) | `{{10, 20}, {50, 60}}` |
| frameBounds.setFrame.bounds | `{{0, 0}, {50, 60}}` |
| frameBounds.setFrameOrigin.frame (setFrameOrigin:(15,25)) | `{{15, 25}, {100, 100}}` |
| frameBounds.setFrameOrigin.bounds | `{{0, 0}, {100, 100}}` |
| frameBounds.setFrameSize.frame (setFrameSize:(150,80)) | `{{0, 0}, {150, 80}}` |
| frameBounds.setFrameSize.bounds | `{{0, 0}, {150, 80}}` |
| frameBounds.setBounds.bounds (setBounds:(5,5,50,50)) | `{{5, 5}, {50, 50}}` |
| frameBounds.setBounds.frame | `{{0, 0}, {100, 100}}` |
| frameBounds.setBoundsOrigin.bounds (setBoundsOrigin:(10,10)) | `{{10, 10}, {100, 100}}` |
| frameBounds.setBoundsOrigin.frame | `{{0, 0}, {100, 100}}` |
| frameBounds.setBoundsSize.bounds (setBoundsSize:(50,50)) | `{{0, 0}, {50, 50}}` |
| frameBounds.setBoundsSize.frame | `{{0, 0}, {100, 100}}` |
| frameBounds.scale.mid_bounds (mid frame 100×100, bounds set to 50×50) | `{{0, 0}, {50, 50}}` |
| frameBounds.scale.convertRect_inner_to_outer (2× scale via bounds/frame mismatch; inner rect (0,0,5,5) in a (10,10,10,10)-frame subview of the scaled mid, converted to outer) | `{{20, 20}, {10, 10}}` |
| frameBounds.centerScanRect (input (10.3,10.7,20.4,20.6)) | `{{10, 11}, {20, 21}}` |
| frameBounds.backingAlignedRect (input (10.3,10.7,20.4,20.6), NSAlignAllEdgesNearest) | `{{10, 11}, {21, 20}}` |
| frameBounds.zeroDimension.rotated_bounds (frameRotation 45, then setFrameSize:(0,100)) | `{{0, 0}, {0, 100}}` |
| frameBounds.zeroDimension.rotated_frame | `{{0, 0}, {0, 100}}` |

Note: `backingAlignedRect:options:` was run on a runner with no attached
screen/backing scale context (borderless, non-displayed process); the result
above reflects that environment's default (1×) backing scale, not necessarily
a Retina (2×) runner's answer.

## rotation

All windowless.

| probe id | AppKit value |
|---|---|
| rotation.setFrameRotation.frameRotation (setFrameRotation:30) | `30.000000` |
| rotation.setFrameRotation.frame | `{{0, 0}, {100, 100}}` |
| rotation.setBoundsRotation.boundsRotation (setBoundsRotation:30) | `30.000000` |
| rotation.setBoundsRotation.bounds | `{{0, -49.999999999999993}, {136.60254037844388, 136.60254037844388}}` |
| rotation.rotateByAngle.frameRotation (fresh view, rotateByAngle:15) | `0.000000` |
| rotation.rotateByAngle.twice.frameRotation (setFrameRotation:10, then rotateByAngle:15) | `10.000000` |
| rotation.nonaxis.convertPoint (subview frame origin (50,50) size 100×100, frameRotation:45, convert point (10,10) to outer) | `{50, 64.142135623730951}` |
| rotation.nonaxis.convertRect (same setup, convert rect (10,10,20,20) to outer) | `{{35.857864376269077, 64.142135623730923}, {28.284271247461845, 28.284271247461845}}` |

Note: `rotation.rotateByAngle.frameRotation` reading `0.000000` after
`rotateByAngle:15` on a fresh (unrotated) view is the value AppKit printed —
recorded verbatim, not interpreted. (`rotateByAngle:twice` confirms
`rotateByAngle:` does accumulate against a pre-set rotation: `10 → 10`, i.e.
that probe's *input* was 10 with no further `rotateByAngle:` applied in that
line — see the probe source for the exact sequence before treating this as a
no-op finding.)

## autoresize

Windowless. Superview `sup` starts at `(0,0,100,100)` with
`setAutoresizesSubviews:YES`; subview `sub` starts at `(10,10,30,30)` (unless
noted); `[sup setFrameSize:(200,150)]` triggers the resize. Fresh views per
probe.

| probe id | AppKit value |
|---|---|
| autoresize.mask.none | `{{10, 10}, {30, 30}}` |
| autoresize.mask.widthSizable | `{{10, 10}, {130, 30}}` |
| autoresize.mask.heightSizable | `{{10, 10}, {30, 80}}` |
| autoresize.mask.widthHeightSizable | `{{10, 10}, {130, 80}}` |
| autoresize.mask.minXMargin | `{{110, 10}, {30, 30}}` |
| autoresize.mask.maxXMargin | `{{10, 10}, {30, 30}}` |
| autoresize.mask.centerX (minXMargin\|maxXMargin) | `{{24, 10}, {30, 30}}` |
| autoresize.mask.centerY (minYMargin\|maxYMargin) | `{{10, 17}, {30, 30}}` |
| autoresize.mask.centerXY (all four margins) | `{{24, 17}, {30, 30}}` |
| autoresize.mask.all (width\|height\|all margins) | `{{20, 15}, {60, 45}}` |
| autoresize.rounding.fractional_grow (sub (10,10,33,33), width+height sizable, sup resized to (151,151)) | `{{10, 10}, {84, 84}}` |

## visibleClip

`visibleRect` was probed both windowless and inside a borderless window that
is created but never ordered front / made key. The windowless probes returned
AppKit's unbounded sentinel rect (no clip context at all); the windowed
(but not on-screen) probes returned a bounded rect but **not** intersected
with the queried view's own bounds — see notes below each group. Neither
group required the window to actually be displayed on screen.

| probe id | AppKit value | needs window |
|---|---|---|
| visibleRect.fullyVisible (sub (10,10,50,50) in outer (0,0,200,200), no window) | `{{-8.9884656743115785e+307, -8.9884656743115785e+307}, {1.7976931348623157e+308, 1.7976931348623157e+308}}` | no |
| visibleRect.partiallyClipped (sub (80,80,50,50) in outer (0,0,100,100), no window) | `{{-8.9884656743115785e+307, -8.9884656743115785e+307}, {1.7976931348623157e+308, 1.7976931348623157e+308}}` | no |
| visibleRect.nested (mid (0,0,50,50) in outer (0,0,200,200); inner (0,0,100,100) in mid, no window) | `{{-8.9884656743115785e+307, -8.9884656743115785e+307}, {1.7976931348623157e+308, 1.7976931348623157e+308}}` | no |
| visibleRect.windowed.fullyVisible (sub (10,10,50,50) in a borderless (0,0,200,200) window's contentView) | `{{-10, -10}, {200, 200}}` | yes |
| visibleRect.windowed.partiallyClipped (sub (80,80,50,50) in a borderless (0,0,100,100) window's contentView) | `{{-80, -80}, {100, 100}}` | yes |
| visibleRect.windowed.nested (mid (0,0,50,50) in a borderless (0,0,200,200) window's contentView; inner (0,0,100,100) in mid) | `{{0, 0}, {200, 200}}` | yes |
| scroll.scrollRectToVisible.documentVisibleRect (NSScrollView (0,0,100,100), document 500×500, scrollRectToVisible:(300,300,50,50), no window) | `{{250, 250}, {100, 100}}` | no |
| scroll.scrollRectToVisible.windowed.documentVisibleRect (same, NSScrollView placed inside a borderless window's contentView) | `{{250, 250}, {100, 100}}` | yes (result identical to windowless) |

Windowless-vs-windowed note on `visibleRect.windowed.*`: each windowed value
equals the *window's content-view bounds expressed in the queried view's own
coordinate system*, without any intersection against that view's own bounds
size (e.g. `partiallyClipped`'s sub is only 50×50 but the returned rect is
100×100). Whether that is "the real AppKit clip rect for a laid-out,
on-screen view" or an artifact of the window never being ordered front is
not resolved by this run — it is recorded as AppKit's actual answer for a
*created-but-not-displayed* window, which is the closest the macOS runner and
the GNUstep xvfb CI lane both can reach without genuine on-screen display.
Treat `visibleRect.windowed.*` values as provisional ground truth for that
specific (window created, never shown) scenario; suite authors should note
this scenario explicitly rather than assume it matches a fully on-screen
window.

## Divergences

(none recorded yet — this file only records the Task 1 sweep; Tasks 2-6
append confirmed GNUstep divergences here as they run each suite against
these values.)
