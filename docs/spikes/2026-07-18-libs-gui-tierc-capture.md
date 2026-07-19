# Spike: Tier C capture mechanism (op-stream vs bitmap)

Question: is there a font-robust PostScript op-stream capture that works headless,
to use for Tier C render regression instead of pixel bitmaps? Captured 2026-07-18
on the WSL Ubuntu box, gui 0.32 / back-032 cairo, display-less.

## Result: op-stream is NOT available; Tier C uses offscreen bitmap.

Three reachable routes to a PostScript op-stream were tried; all fail in the
installed build.

1. `-[NSView dataWithEPSInsideRect:]` (Probe B, prior spike). Delegates to
   `NSPrintOperation runOperation`; hangs at 100% CPU display-less, exits 0
   without data with a display. Dead.

2. `+[NSGraphicsContext graphicsContextWithAttributes:]` with
   `NSGraphicsContextRepresentationFormatAttributeName = NSGraphicsContextPSFormat`
   and an `NSOutputFile` path (probeD, PATH1). Returns a **`CairoContext`**, not a
   stream context — the PS-format delegation in `GSContext initWithContextInfo:`
   (`libs-back/Source/gsc/GSContext.m:184`) is not reached through the cairo
   default context in this build. No PS file produced.

3. Direct `objc_getClass("GSStreamContext")` + `initWithContextInfo:` with an
   `NSOutputFile` path (probeD, PATH2). The instance is created and opens the
   file, but rendering a view into it produces a **0-byte** file, and
   `flushGraphics` raises `subclass GSStreamContext(instance) should override
   flushGraphics`. `GSStreamContext` is a legacy PostScript context driven by the
   printing machinery; it is not usable standalone for op capture and emits
   nothing for a normal view draw.

Making the op-stream work would require patching `libs-back/Source/gsc`
(implement `flushGraphics`, make the op methods emit for a standalone render, or
fix the PS-format delegation). That is out of scope for the harness and touches
the retiring gsc/PostScript path.

## Decision

Tier C render regression uses the **offscreen bitmap** path. The confirmed
view-render mechanism (probeE, verified display-less and under Xvfb, identical
`RED_OK` result):

- Create an offscreen `NSWindow` (works headless per Probe C), set the view as
  its content view.
- `[view lockFocus]`, `[view drawRect: bounds]`, capture with
  `[[NSBitmapImageRep alloc] initWithFocusedViewRect:]`, `[view unlockFocus]`.
- Read pixels with `-[NSBitmapImageRep colorAtX:y:]`.

`NSView` has no `cacheDisplayInRect:toBitmapImageRep:` in this build, and routing
a windowless view through `displayRectIgnoringOpacity:inContext:` into an
`NSImage`'s focus does NOT populate the bitmap (pixels come back NaN). The
window + view-lockFocus path is the one that works. `NSImage lockFocus` with
direct drawing (Probe A) works too, but only for drawing done inline, not for a
view's `drawRect:`.

To avoid the freetype/antialiasing cross-environment fragility that killed the
idea of shared golden images:

- Assert **pixel colours at known coordinates** for views that draw solid
  shapes/borders/fills (deterministic across cairo versions), not whole-image
  checksums or golden PNGs. This is a render-correctness assertion and doubles as
  a weak layout audit against AppKit (what is drawn where, not the exact pixels).
- Exclude text and antialiased edges from pixel assertions. Text-layout
  correctness is carried by Tier A geometry (glyph and line rects from
  `NSLayoutManager`), not glyph pixels.

Probe file: `~/gnustep-reaudit/.spike-headless-gui/probeD_dps.m` (throwaway).
