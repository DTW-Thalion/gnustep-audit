# Spike: Glyph Caching for CoreText / libs-opal

**Date:** 2026-04-13
**Author:** Claude subagent (Opus 4.6)
**Status:** DRAFT - pending review
**Target repo:** libs-opal

---

## 1. Current state

### 1.1 The glyph rasterization path

The text rendering call graph in libs-opal is short. For the Core Text entry
points, the path is:

- `CTFrameDraw` -> `CTLineDraw` at `libs-opal/Source/OpalText/CTFrame.m:101`
- `CTLineDraw` -> `CTRunDraw` at `libs-opal/Source/OpalText/CTLine.m:51`
- `CTRunDraw` -> `CGContextShowGlyphsAtPositions` at
  `libs-opal/Source/OpalText/CTRun.m:106`
- `CGContextShowGlyphsAtPositions` -> `cairo_show_glyphs` in a per-glyph loop
  at `libs-opal/Source/OpalGraphics/CGContext.m:1821-1823`

Note that `CTFontDrawGlyphs` is an **unimplemented stub** - it is a plain
`return;` at `libs-opal/Source/OpalText/CTFont.m:539-547`. Anyone calling the
"direct" Core Text glyph-drawing API gets nothing; in practice the only
rasterization path is via `CGContextShowGlyphs*`.

Lower-level CG calls land in the same place:

- `CGContextShowGlyphs` at `libs-opal/Source/OpalGraphics/CGContext.m:1717`
  forwards to `CGContextShowGlyphsWithAdvances` which ultimately computes
  positions and calls `CGContextShowGlyphsAtPositions`.
- `CGContextShowText` at `libs-opal/Source/OpalGraphics/CGContext.m:1616` uses
  the simpler Cairo toy-text API (`cairo_show_text` at line 1676).

The workhorse is `CGContextShowGlyphsAtPositions`
(`CGContext.m:1763-1825`). After computing a fresh `cairo_text_matrix` and
calling `cairo_set_font_matrix` (line 1809), it contains this loop:

```
// FIXME: Report this as a cairo bug.. the following places the glyphs
// after the first one incorrectly
//cairo_show_glyphs(ctx->ct, cairoGlyphs, count);
// WORKAROUND:
for (int i=0; i<count; i++) {
  cairo_show_glyphs(ctx->ct, &(cairoGlyphs[i]), 1);
}
```
(`libs-opal/Source/OpalGraphics/CGContext.m:1818-1823`)

This is the actual rasterization entry point.

### 1.2 Where `cairo_scaled_font_t` comes from

This is the critical question for the spike. Answer: **libs-opal creates
exactly one `cairo_scaled_font_t` per `CGFontRef` at font-creation time,
stores it on the font object, and reuses it for the lifetime of the font.**

Concretely:

- `CairoFont` is an `@public` ObjC class holding `cairo_scaled_font_t
  *cairofont;` at `libs-opal/Source/OpalGraphics/cairo/CairoFont.h:28-32`.
- The Win32 backend creates the scaled font in `+createWithFontName:` at
  `libs-opal/Source/OpalGraphics/cairo/CairoFontWin32.m:358-389`. Line 389 is
  the sole call: `font->cairofont = cairo_scaled_font_create(unscaled, &ident,
  &ident, opts);`. This runs once per `CGFontCreateWithFontName`.
- The X11 backend is symmetric: `cairo_scaled_font_create` at
  `libs-opal/Source/OpalGraphics/cairo/CairoFontX11.m:464`, called inside
  `+createWithFontName:` starting at line 444.
- The `CGFontCreateWithFontName` public entry at
  `libs-opal/Source/OpalGraphics/CGFont.m:248-251` simply forwards to `[[CGFont
  fontClass] createWithFontName:]`, and `+fontClass` at `CGFont.m:44-50`
  returns `CairoFontWin32` on MinGW / `CairoFontX11` elsewhere.
- Destruction is tied to ObjC dealloc: `cairo_scaled_font_destroy(cairofont);`
  at `libs-opal/Source/OpalGraphics/cairo/CairoFont.m:30-34`. The scaled font
  lives exactly as long as the `CGFontRef`.

So the `CGFontRef -> cairo_scaled_font_t` binding is 1:1 and lifetime-matched.
A second `CGFontCreateWithFontName(@"Helvetica")` does allocate a second
scaled font (there is no `CGFont`-level dedup cache), but **within a single
`CGFontRef` instance there is no per-draw scaled-font recreation.**

### 1.3 How the scaled font reaches `cairo_show_glyphs`

`CGContextSetFont` at `libs-opal/Source/OpalGraphics/CGContext.m:1543-1553`
pulls the `cairo_font_face_t` out of the scaled font with
`cairo_scaled_font_get_font_face(((CairoFont*)font)->cairofont)` (line 1550)
and installs it on the Cairo context via `cairo_set_font_face`. It does
**not** reinstall the scaled font - it installs the *face* and lets
`CGContextShowGlyphsAtPositions` set a fresh per-call font matrix via
`cairo_set_font_matrix` (`CGContext.m:1809`).

This matters. When Cairo sees `face + matrix + ctm + font_options`, it
internally materializes a `cairo_scaled_font_t` keyed on that tuple and
caches it in its scaled-font cache (Cairo's `_cairo_scaled_font_map`). The
`cairo_scaled_font_t` that libs-opal stored on `CairoFont` is effectively
unused for drawing - it exists only so that libs-opal can call
`cairo_scaled_font_get_font_face`, `cairo_scaled_font_extents`
(`CairoFontX11.m:421`), and `FT_Load_Glyph` against the underlying face
(`CairoFontX11.m:498, 513`).

### 1.4 Does Cairo cache glyph bitmaps?

Yes. From `/c/msys64/ucrt64/include/cairo/cairo.h:1097-1113`:

> `cairo_scaled_font_t`: A #cairo_scaled_font_t is a font scaled to a
> particular size and device resolution. A #cairo_scaled_font_t is most
> useful for low-level font usage...

Cairo's documented and long-standing behavior (see `cairo-scaled-font.c` in
the Cairo source; the `_cairo_scaled_glyph_lookup` / `CAIRO_SCALED_GLYPH_INFO_*`
machinery) is that each `cairo_scaled_font_t` maintains an internal per-glyph
cache of metrics, surfaces, and paths, populated lazily on first access and
evicted under LRU pressure. Every call to `cairo_show_glyphs` goes through
`_cairo_scaled_font_glyph_device_extents` / `_cairo_scaled_glyph_lookup`,
which are cache hits after the first rasterization of a given
`(scaled_font, glyph_index)` pair.

Additionally, Cairo maintains a global `cairo_scaled_font_map` that
deduplicates `cairo_scaled_font_t` instances by `(face, font_matrix, ctm,
options)`. So even though libs-opal calls `cairo_set_font_matrix` on every
`CGContextShowGlyphsAtPositions` (`CGContext.m:1809`), Cairo will reuse the
same underlying scaled-font cache entry as long as the matrix/ctm/options
tuple is stable across draws.

### 1.5 Holes in reuse

There are three places where Cairo's cache can still miss:

1. Every `CGContextShowGlyphsAtPositions` call rebuilds the cairo font matrix
   from scratch (`CGContext.m:1791-1809`) by multiplying flip * font_size *
   text matrix. If the text matrix or font size changes between draws - even
   by FP noise - Cairo sees a new key and builds a new scaled-font entry.
   The stable-tuple case still hits Cairo's glyph cache.
2. The per-glyph loop at `CGContext.m:1821-1823` calls `cairo_show_glyphs`
   once per glyph. This does not defeat the glyph bitmap cache (each
   individual call is a cache hit after first use), but it does force Cairo
   to set up rendering state N times per draw and pay N batched-blit costs
   instead of one. This is a real cost but it is not a glyph-caching problem.
3. `CGContextShowGlyphsAtPositions` never calls `cairo_set_scaled_font` with
   the pre-built `((CairoFont*)font)->cairofont`. If the font_matrix on that
   prebuilt scaled_font happens to match the per-call matrix, we would get
   one extra indirection saved, but in the common case (draws at a user-chosen
   pointSize != 1) it would not match anyway - the prebuilt scaled_font is
   identity-scaled (`CairoFontWin32.m:382-389`, `CairoFontX11.m:454-464`).

## 2. Proposed change

Given §1, the original spike framing ("add a glyph bitmap cache on top of
Cairo") is **the wrong intervention**. Cairo already does exactly that, and
libs-opal is already plumbing the font face through in a way that lets
Cairo's cache fire. The naive glyph-cache design would duplicate work Cairo
already does, add memory pressure, and not win the benchmark.

There are three much smaller, cheaper changes that are worth considering, in
rough order of payoff-to-effort:

**Option A (needs investigation, not a free swap):** Investigate whether the
2010 per-glyph workaround loop at `CGContext.m:1821-1823` is masking an
**opal-side glyph-position computation bug**, then — only if that investigation
clears — replace it with a single `cairo_show_glyphs(ctx->ct, cairoGlyphs,
count)`.

The 2010 `FIXME` attributes the miscompilation to a Cairo bug ("the following
places the glyphs after the first one incorrectly"). That attribution is
implausible on its face: `cairo_show_glyphs` is Cairo's primary batch text
API and has been in continuous production use for ~20 years by GTK, Firefox,
Poppler, Evince, and essentially every Cairo-backed text stack. A bug of the
form "glyphs after the first one are placed incorrectly" would not have
survived that level of exposure. The far more likely explanation is
**opal-side**: the `cairoGlyphs[].x/.y` positions filled in at
`CGContext.m:1783-1785` (and the parallel path in
`CGContextShowGlyphsWithAdvances`) are authored in the wrong coordinate space,
and the per-glyph `count=1` call masks the bug because a single-glyph
`cairo_show_glyphs` call does not accumulate inter-glyph advance width — so
an absolute-vs-relative or user-space-vs-font-space mixup is invisible until
a batched call asks Cairo to advance between glyphs.

Before touching the loop, the implementation plan must:

  (a) **Audit how `cairoGlyphs[].x/.y` are filled in the callers.** Read
      `CGContextShowGlyphsAtPositions` and `CGContextShowGlyphsWithAdvances`
      around `CGContext.m:1831+` and trace every write into the
      `cairoGlyphs[]` array.
  (b) **Confirm the positions are in the font's user space** after the
      `cairo_set_font_matrix` call at `CGContext.m:1809` — Cairo will
      interpret `cairo_glyph_t.x/.y` under the current font matrix, so a
      mismatch there is precisely the failure mode the 2010 workaround masked.
  (c) **Add a visual regression test for multi-glyph strings at non-identity
      text matrices** (scale, rotate, skew) that compares pre-change and
      post-change output pixel-for-pixel at identity and within tolerance at
      rotated matrices. Without this fixture, an "it looks fine on Hello
      World" check will not surface the exact class of bug the 2010 comment
      was guarding against.

If the audit finds the position fill path is correct and the regression test
passes with the batched call, the per-glyph loop can be removed. If the audit
finds a coordinate-space bug, the fix belongs at the fill site, not at the
`cairo_show_glyphs` call.

**Option B:** Deduplicate `CGFontRef` at `CGFontCreateWithFontName` level.
Currently every call allocates a new `CairoFontWin32`/`CairoFontX11` instance
with a new HFONT/FT_Face/`cairo_scaled_font_t`. Adding a simple
`NSMapTable<NSString*, CGFontRef>` weak-value cache keyed on the font name
(in `CGFont.m` near line 248) would collapse N Helvetica creations to one,
which in turn means one font-face registration in Cairo's global
`scaled_font_map` instead of N. This is a CGFont-identity cache, not a glyph
cache, but it is in the same spirit as the spike.

**Option C (not recommended now):** A text-run cache keyed on
`(CGFontRef, pointSize, glyph-sequence-hash, text-matrix)` mapping to a
pre-rendered `cairo_surface_t`. This is the only thing Cairo does *not* do
for you. It is worth revisiting only if profiling shows the
`CTFramesetter`/`CTLine` build cost dominates in real NSTextView scenarios;
in that case the cache should live on `CTLine`, not on `CGFont`. Out of
scope for this spike.

The recommended §7 proposal is **Option A, with Option B as a follow-up**.

## 3. ABI impact

**None for Option A.** The change is inside the `CGContextShowGlyphsAtPositions`
function body; no header, no struct layout, no symbol signature touched.

**None for Option B either**, assuming the dedup table is internal to
`CGFont.m`. `CGFontRef` is typedef'd as `typedef struct CGFont* CGFontRef` at
`libs-opal/Headers/CoreGraphics/CGFont.h:34` (with a parallel `typedef CGFont*
CGFontRef` at line 32 for the ObjC compilation path). The `struct CGFont` is
forward-declared only in the public header - its full definition is in the
internal header `libs-opal/Source/OpalGraphics/internal/CGFontInternal.h`
(viewable at lines ~38-53 where the `@interface CGFont : NSObject` declares
its ivars). The struct is opaque to callers, so adding a dedup cache is pure
refactor.

The one watch-out is that `CGFontRelease` currently calls through to ObjC
`-release`; if the dedup cache holds strong refs, callers that retain/release
symmetrically will keep refcounts positive and the scaled_font will never
free. A proper implementation needs either weak-valued NSMapTable or an
explicit last-release hook to evict.

## 4. Performance estimate

No bench exists for text drawing. `gnustep-audit/instrumentation/benchmarks/`
contains `bench_autorelease`, `bench_cfarray_append`, `bench_dict_lookup`,
`bench_image_draw`, `bench_msg_send`, `bench_nscache`, `bench_retain_release`,
`bench_runloop_timers`, `bench_scroll`, `bench_string_hash`,
`bench_view_invalidation`, `bench_weak_ref` - no text benchmark. A new
`bench_text_draw.m` would need to:

1. Create one `CGBitmapContext` (offscreen ARGB32).
2. `CGFontCreateWithFontName(@"Helvetica")` once outside the timed region.
3. Loop N=100000 times: `CGContextShowGlyphsAtPositions(ctx, glyphs, pos, 10)`
   for a fixed 10-glyph array.
4. Report ns/draw and ns/glyph.

Order-of-magnitude estimates from first principles on ucrt64 clang
gnustep-2.0 + cairo 1.18:

| Operation                                      | Cost       | Notes |
|------------------------------------------------|------------|-------|
| `cairo_scaled_font_create` (cold, per font)    | 1-5 ms     | FT face load, OT tables, metrics |
| `cairo_scaled_font_create` (warm, global map)  | 1-10 us    | hash lookup in `cairo_scaled_font_map` |
| First-ever rasterize of one glyph              | 50-300 us  | FT render + cache populate |
| Cached glyph lookup in `cairo_scaled_font_t`   | ~100 ns    | `_cairo_scaled_glyph_lookup` hash hit |
| `cairo_show_glyphs(ctx, g, 1)` per-call overhead | 1-3 us   | path setup, clip check, compositor dispatch |
| `cairo_set_font_matrix` (matrix changes)       | 100-500 ns | may invalidate current scaled_font binding |

With the current code, a 10-glyph draw at steady state is roughly
`10 * (per-call overhead)` + negligible rasterization = **10-30 us/draw**.
A successful Option A collapses that to `1 * per-call overhead` =
**1-3 us/draw**, roughly a **5-10x** speedup on the draw body for
repeat-same-string scenarios — **but only IF the underlying opal-side
glyph-position fill path is verified correct first**. If the position fill
path has the latent bug hypothesized in §2, the "fix" is not a performance
win at all; it is a **correctness regression** that ships visibly wrong text
layout to every caller. The risk here is a correctness regression, not a
performance miss. First-draw cost is unchanged either way — it is dominated
by FreeType rasterization which Cairo already caches.

If the real workload is "draw 100 different glyph strings per frame, mostly
ASCII, from one font" (typical NSTextView), the expected win is also in the
5-10x range because the per-call overhead dominates and the glyph cache is
already warm.

Option B wins only the first-draw scaled_font create cost (the 1-5 ms
number) and only if the caller is repeatedly creating+destroying the same
CGFont. For long-lived applications this is close to zero.

## 5. Risk

**Option A risks:**

1. The 2010 comment at `CGContext.m:1818` might be correct. If modern Cairo
   still mispositions multi-glyph runs in some edge case (transforms with
   skew, subpixel positioning, etc.), the visual regression will be
   immediate. Mitigation: run `libs-opal/Tests/texttest.m` and
   `textlayout.m` before and after, diff the PNGs.
2. The per-glyph path has been in place for ~16 years and may be masking
   a latent positioning bug in the `cairoGlyphs[i].x/.y` computation at
   `CGContext.m:1783-1785`. Fixing that bug is in scope for this spike
   if Option A surfaces it.
3. Thread safety: `cairo_scaled_font_t` is documented thread-safe for
   rendering (multiple threads may `cairo_show_glyphs` against one), but
   `cairo_scaled_font_create` / `_destroy` must be serialized by the
   caller. libs-opal currently does not serialize; `CairoFont.m:32`
   destroys from `-dealloc` which can race with another thread's draw if
   the `CGFontRef` refcount is dropped concurrently. This is a pre-existing
   bug, not introduced by Option A, but note it.
4. **Cross-thread `cairo_font_face_t` lifetime (pre-existing, out of
   scope for B4).** `CGContextSetFont` at `CGContext.m:1550` passes the
   raw `cairo_font_face_t` out of the `CairoFont` wrapper via
   `cairo_scaled_font_get_font_face(...)` and installs it on the Cairo
   context **without retaining the `CairoFont`** and **without calling
   `cairo_font_face_reference` on the returned face**. The face's
   lifetime is therefore tied to the `CairoFont`'s lifetime, and
   cross-thread safety depends entirely on caller discipline: if thread
   A is mid-draw against a `CGContextRef` that was configured with a
   `CGFontRef`, and thread B drops the last refcount on that same
   `CGFontRef`, `-[CairoFont dealloc]` calls `cairo_scaled_font_destroy`
   which tears down the face thread A is still using. This is a
   pre-existing issue, out of scope for B4 and for Option A, but noted
   here so future readers of this spike are aware it is lurking in the
   same code region.

**Option B risks:**

1. Lifetime management of a process-wide font cache - font names are
   user-supplied strings, so the cache is effectively unbounded without an
   LRU. Memory pressure per cached CairoFont is modest (~tens of KB for the
   FT face tables plus whatever Cairo caches) but not zero.
2. Variable fonts and color (COLR/CPAL, CBDT) fonts: the existing code uses
   identity matrices at creation time and does not distinguish variation
   axes, so a dedup cache keyed only on the font *name* is correct only
   because the existing code was already lossy about variations. Not a
   regression, but worth documenting.

## 6. Test strategy

1. **Visual regression baseline.** The existing manual test harness is
   `libs-opal/Tests/texttest.m` (it calls `CGFontCreateWithFontName` at
   lines 134 and 149) and `libs-opal/Tests/textlayout.m`. Neither is a
   real comparison framework; they render to a window. For a before/after
   check, redirect output to `CGBitmapContext`, `CGImageDestinationRef` ->
   PNG, and byte-compare. Accept <1% pixel diff.
2. **New benchmark.** Add `bench_text_draw.m` alongside the existing
   benches under `gnustep-audit/instrumentation/benchmarks/`. Model it on
   `bench_image_draw.m` (same harness, same output format). Report
   ns/draw for a fixed 10-glyph string, repeated 100k times, with one
   long-lived `CGFontRef` and one long-lived `CGBitmapContext`. This
   isolates Option A's win and makes Option B's win trivially measurable
   ("ns to first draw").
3. **Targeted unit**. Write a tiny test that draws the same glyph array
   into two bitmap contexts - one using the per-glyph loop, one using
   single `cairo_show_glyphs` - and asserts pixel-exact equality for the
   identity text matrix and 1%-tolerance equality for a scale+rotate text
   matrix. This is the direct validation of Option A.
4. **Thread-safety smoke test.** Create one `CGFontRef`, spawn 4 threads
   each running 10k `CGContextShowGlyphsAtPositions` against their own
   `CGBitmapContext` but sharing the `CGFontRef`. Verify no crashes, no
   Cairo status errors. Pre-existing; used here only as a regression gate.

## 7. Decision

**NO-GO on the spike as originally framed** (adding a new glyph bitmap
cache layered on top of Cairo). Rationale: Cairo's
`cairo_scaled_font_t` already owns a per-glyph bitmap cache, libs-opal
already holds one `cairo_scaled_font_t` for the lifetime of each
`CGFontRef` (`CairoFontWin32.m:389`, `CairoFont.m:32`), and the face
reaches `cairo_show_glyphs` via `cairo_set_font_face` at
`CGContext.m:1550` in a way that lets Cairo's scaled-font map
deduplicate correctly across draws. Adding another cache would duplicate
work and add memory pressure without addressing any real bottleneck.

The redirected work is **NOT** a spike deliverable and is **NOT** a "quick
follow-up with zero ABI impact." It is scoped as follows:

- **B4a (NEEDS-DISCUSSION / separate plan):** The `cairo_show_glyphs`
  batching fix at `libs-opal/Source/OpalGraphics/CGContext.m:1821-1823`.
  This requires its own brainstorm and written plan, **starting with
  reproducing the original miscompilation** that prompted the 2010
  workaround. Until that miscompilation is reproduced and its root cause
  identified (almost certainly an opal-side coordinate-space bug in the
  `cairoGlyphs[].x/.y` fill path per §2, not a Cairo bug), removing the
  per-glyph loop is not safe. The expected 5-10x speedup is conditional
  on the opal-side bug being found and fixed; otherwise the change is a
  correctness regression. Do not present this as a drop-in follow-up.
- **B4b (NEEDS-DISCUSSION, medium):** CGFont-identity dedup in
  `CGFontCreateWithFontName` at `CGFont.m:248`. Small behavioral change
  (refcount semantics with a dedup table) and unclear whether the
  first-draw cost matters in real applications. Worth a profiler run
  against a realistic NSTextView workload before committing.

Prior spikes B1 (per-class cache version), B2 (tagged pointer NSString),
and B3 (dtable cache line) are all runtime-layer and do not interact with
this decision.

**Headline finding:** The spike's core hypothesis is confirmed - Cairo
already caches glyph bitmaps internally and libs-opal is already hooked
up to benefit from that cache. The visible per-draw cost is not
rasterization; it is the 1-glyph-per-call `cairo_show_glyphs` workaround
loop introduced in 2010. However, that loop is **not** a "free removal":
the 2010 comment blames Cairo, but a `cairo_show_glyphs` batch-API bug of
that form would not have survived 20 years of GTK/Firefox/Poppler
production use, so the real cause is almost certainly an opal-side
coordinate-space bug in the `cairoGlyphs[].x/.y` fill path that the per-
glyph `count=1` call masks. Resolving this requires its own plan that
begins with reproducing the original miscompilation, not a one-line edit
in this spike.
