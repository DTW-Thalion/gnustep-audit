# Phase 6: Runtime Optimization Deep Dive

**Date:** 2026-04-12
**Status:** Sprint 1-3 complete (15/15 tasks). Task 9 (NSRunLoop timer optimization) was deferred at audit close and is now tracked by the follow-up plan at `docs/superpowers/plans/2026-04-12-phase6-followup.md`, which also covers the Sprint 4/5 architectural items below as design spikes. PF-7 (`__sync_fetch_and_add` → `__atomic_load_n`) fully closed by libobjc2 commit `834c978`.
**Scope:** Cross-cutting performance optimization across all 7 repos
**Informed by:** Findings from Phases 1-5

---

## Executive Summary

This phase synthesizes all performance findings into a unified optimization roadmap. The GNUstep stack has systemic performance issues at every layer:

- **Runtime (libobjc2):** Single global weak ref lock, unnecessary full barriers in retain/release, dtable in wrong cache line
- **Foundation (libs-base):** Broken NSCache (O(n) per access), O(n) timer processing, no small-string optimization
- **CoreFoundation (libs-corebase):** CFArray linear growth (O(n^2) appends), per-iteration malloc in CFRunLoop, broken bridging enumeration
- **Graphics (libs-opal + libs-quartzcore):** Presentation layer recreated every frame, full texture re-upload every frame, no glyph caching
- **UI (libs-gui + libs-back):** Single bounding-rect dirty tracking, no expose coalescing, no resize throttling, pixel format conversion on every image draw

---

## 1. Message Dispatch Optimization

### 1.1 IMP Cache Architecture

**Current state:** Global `objc_method_cache_version` counter. Any method change in any class invalidates ALL cached IMPs system-wide.

**Problem:** KVO, dynamic method resolution, and category loading each bump the global version, causing cache storms that affect every call site in the application.

**Recommendation: Per-class generation counters**
- Replace global `objc_method_cache_version` with a per-class `uint64_t cache_generation` field
- On method list change, increment only the affected class and its subclasses
- Callsite caches store `(class, generation, IMP)` tuples
- **Effort:** Large (ABI change + all cache sites updated)
- **Impact:** Eliminates system-wide invalidation; KVO on one object no longer invalidates unrelated call sites

### 1.2 objc_msgSend Fast Path

**Current state (x86-64):** 12 instructions, 5 memory loads, 4 branches, 1 indirect jump. Two unnecessary red-zone spills (rax/rbx) on every call.

**Optimizations:**
| Change | Saves | Effort |
|--------|-------|--------|
| Remove rax/rbx red-zone spills | 2 stores + 2 loads (~2-4 cycles) | Small |
| Use AND-immediate for SMALLOBJ_MASK instead of movq | 7 bytes I-cache | Small |
| Move `dtable` field adjacent to `isa` in class struct | 1 cache line miss (~5-10ns cold) | Large (ABI) |
| Add `__attribute__((aligned(64)))` to `objc_method_cache_version` | Eliminates false sharing | Trivial |

### 1.3 Branch Prediction

**Current state:** `objc_msgSend` dispatches on dtable depth via `cmp + je` chain (shift=8, 0, 16, 24). Most classes have <256 selectors, so shift=8 is the common case.

**Recommendation:** Reorder the branch chain so shift=8 is the first comparison (it currently is on x86-64 but not on AArch64). Use `__builtin_expect` in the C slow path.

---

## 2. Memory Management Optimization

### 2.1 Weak Reference Lock Striping

**Current state:** Single global `weakRefLock` mutex for ALL weak reference operations.

**Impact:** Measured 5-8x throughput reduction under 8-thread concurrent weak ref workload.

**Recommendation:**
```
#define WEAK_LOCK_COUNT 64
static mutex_t weakRefLocks[WEAK_LOCK_COUNT];
#define WEAK_LOCK_FOR(obj) (&weakRefLocks[((uintptr_t)(obj) >> 4) % WEAK_LOCK_COUNT])
```
- **Effort:** Medium (refactor all weak ref functions to use per-object lock)
- **Impact:** Near-linear scaling for concurrent weak ref operations

### 2.2 Retain/Release Atomic Load Fix

**Current state:** `__sync_fetch_and_add(refCount, 0)` used as atomic load (full barrier).

**Fix:** Replace with `__atomic_load_n(refCount, __ATOMIC_RELAXED)` in `retain_fast` and `release_fast`.
- **Effort:** Trivial (mechanical replacement in arc.mm)
- **Impact:** Saves ~10-20 cycles per retain/release on ARM; ~5 cycles on x86-64

### 2.3 Autorelease Pool Optimization

**Current issues:**
1. TLS access via `pthread_getspecific` / `FlsGetValue` on every autorelease (~5-10ns)
2. No pool page recycling (free on drain, calloc on push)
3. libs-base nested pool init does O(depth) parent walk

**Recommendations:**
| Change | Impact | Effort |
|--------|--------|--------|
| Per-thread pool page free list (recycle instead of free) | Eliminates malloc/free per push/pop | Small |
| Track pool depth as counter in TLS struct | O(1) depth check instead of O(depth) walk | Small |
| On AArch64: reserve register for pool TLS pointer | Eliminates function call per autorelease | Medium |

### 2.4 NSZone Removal Assessment

**Current state:** Zone-based allocation adds a function pointer indirection and zone lock to every malloc. The default zone just calls system malloc.

**Recommendation:** Deprecate custom zones. Keep the API but route all allocations through system malloc, eliminating the zone lock and vtable overhead. This is what Apple did in macOS 10.6+.
- **Effort:** Medium
- **Impact:** Eliminates zone mutex contention in libs-base; simplifies allocation fast path

---

## 3. Collection Optimization

### 3.1 Small Collection Inline Storage

**Current state:** Every NSArray/NSDictionary/NSSet requires heap allocation regardless of element count. libs-base has `GSInlineArray` for immutable arrays only. No equivalent for mutable arrays, dictionaries, or sets.

**Recommendation:**
| Collection | Threshold | Implementation |
|-----------|-----------|----------------|
| NSArray (immutable) | Already has GSInlineArray | Keep |
| NSArray (mutable) | <=8 elements | Inline buffer in GSMutableArray; spill to heap on growth |
| NSDictionary | <=4 entries | Linear scan `GSSmallDictionary` (Apple has `__NSSingleEntryDictionaryI`) |
| NSSet | <=4 elements | Linear scan `GSSmallSet` |
| CFArray (mutable) | Fix growth to geometric | Change `+16` to `*2` in CFArrayCheckCapacityAndGrow |
| CFMutableString | Fix growth to geometric | Change exact-fit to `*1.5` in CFStringCheckCapacityAndGrow |

### 3.2 Hash Function Quality

**Current state:** libs-base uses various ad-hoc hash functions. libs-corebase uses DJB hash truncated to 28 bits.

**Recommendation:** Standardize on wyhash or SipHash-1-3 for all hash tables:
- Better distribution for short strings with common prefixes (Objective-C selector/class names)
- 64-bit output avoids the 28-bit truncation waste in libs-corebase
- SipHash provides DoS resistance for untrusted inputs (JSON keys, plist keys)

### 3.3 NSFastEnumeration Optimization

**Current state:** Mutable arrays do a `memcpy` per batch in fast enumeration. Dictionaries may lack `mutationsPtr` tracking.

**Recommendation:** For mutable arrays, return direct pointer with mutation version check (like immutable) but handle concurrent modification via copy-on-write rather than pre-copy.

### 3.4 NSString Hash Caching + Small String Optimization

**Current state:** Hash is cached in `_flags.hash` (28-bit) after first computation. No small-string optimization. No encoding conversion cache.

**Recommendations:**
| Change | Impact | Effort |
|--------|--------|--------|
| Implement tagged-pointer NSString for <=11 bytes ASCII | Eliminates 2 heap allocs per short string | Large (requires libobjc2 support) |
| Cache UTF-8 representation lazily on first `UTF8String` call | Eliminates redundant encoding conversions | Medium |
| Use full 64-bit hash (not 28-bit) | Better distribution for large dictionaries | Medium |

---

## 4. I/O and Networking Optimization

### 4.1 NSRunLoop / CFRunLoop

**Current issues (libs-base):**
- O(n) timer scan every iteration (unordered array)
- No timer coalescing

**Current issues (libs-corebase):**
- malloc/free temp arrays for timers, sources, observers on EVERY iteration (5x per loop)
- pipe() wakeup instead of eventfd()
- poll() with only millisecond resolution
- Version-1 sources (port-based) unimplemented

**Recommendations:**
| Change | Impact | Effort |
|--------|--------|--------|
| libs-base: Replace timer array with min-heap per mode | O(log n) timer firing instead of O(n) | Medium |
| libs-base: Implement timer coalescing for nearby fire dates | Reduces wakeups | Medium |
| libs-corebase: Use stack-allocated small buffers (alloca or C99 VLA) for <64 sources | Eliminates malloc/free per iteration | Small |
| libs-corebase: Use eventfd() on Linux, WaitForMultipleObjects on Windows | Fewer fds, proper Windows support | Medium |
| libs-corebase: Use ppoll() for sub-millisecond timer resolution | Microsecond timer accuracy | Small |

### 4.2 NSCache Fix

**Current state:** Fundamentally broken — O(n) per access, never evicts non-discardable objects.

**Fix (P0):**
1. Replace `_accesses` NSMutableArray with doubly-linked list for O(1) LRU update
2. Implement eviction for ALL object types (not just NSDiscardableContent) when cost/count limits exceeded
3. Replace NSRecursiveLock with reader-writer lock for concurrent reads

### 4.3 Serialization

**JSON parser (libs-base):**
| Change | Impact | Effort |
|--------|--------|--------|
| Increase buffer from 64 to 4096 chars | Fewer refills for large docs | Trivial |
| Build short strings directly from stack buffer (skip NSMutableString) | Eliminate alloc for strings <64 chars | Small |
| Detect integer JSON numbers (no `.` or `e`) → parse as long long | Preserves precision, may be faster | Small |
| Add recursion depth limit (e.g., 512) | Prevents DoS stack overflow | Trivial |

---

## 5. Rendering Pipeline Optimization

### 5.1 Dirty Region Tracking

**Current state:** libs-gui NSView uses single `_invalidRect` bounding box. Two 10x10 dirty spots at opposite corners of a 1000x1000 view cause full 1000x1000 redraw.

**Recommendation:** Replace `_invalidRect` with a dirty region (list of up to 8 rects, merged when count exceeds limit). This is what Cocoa uses internally.
- **Effort:** Medium
- **Impact:** Dramatically reduces overdraw for complex views

### 5.2 Expose Event Coalescing

**Current state:** X11 backend has expose coalescing code but it's **disabled** (`#if 0`).

**Fix:** Re-enable the `_addExposedRectangle` / `_processExposedRectangles` mechanism. Accumulate exposed rects while `xEvent.xexpose.count > 0`, then process as single batch.
- **Effort:** Small (code exists, just disabled)
- **Impact:** Eliminates N separate redraws during expose storms

### 5.3 Image Pipeline

**Current state:** CairoGState DPSimage does pixel format conversion (RGBA→ARGB byte swap) with malloc + per-pixel loop on EVERY draw. For 1080p: 8MB alloc + 2M pixel swaps.

**Recommendations:**
1. Cache reformatted image data alongside the original representation
2. Store images in cairo-native ARGB32 from the start where possible
3. Use SIMD byte swapping (SSE2 shuffle or NEON vtbl) for the conversion path
- **Effort:** Medium
- **Impact:** Eliminates dominant cost of image-heavy rendering

### 5.4 Live Resize Throttling

**Current state:** Every pixel of window resize triggers full relayout + redraw with no throttling.

**Recommendation:**
- Throttle resize events to 30-60fps
- During live resize, defer non-essential subview layout
- Use content stretching for intermediate frames
- **Effort:** Medium
- **Impact:** Smooth resize instead of laggy

### 5.5 Scroll Performance

**Current state:** NSClipView copies visible intersection via `scrollRect:by:` then redraws exposed strips. No overdraw buffer, no content caching.

**Recommendation:** Implement overdraw — render a region larger than the visible area so small scrolls don't require any document view redraw. Invalidate overdraw region when scroll exceeds buffer.
- **Effort:** Medium-Large
- **Impact:** Smooth scrolling for content-heavy views

### 5.6 Theme Rendering

**Current state:** GSDrawTiles composites 9 separate images per themed control. 20 buttons = 180 composites.

**Recommendation:** Pre-render tiled control appearance at needed size into a single cached bitmap. Invalidate cache on size change. Single composite per control draw.
- **Effort:** Medium
- **Impact:** 9x reduction in composite operations for themed controls

### 5.7 CALayer Presentation Layer

**Current state:** Presentation layer destroyed and recreated every frame. N layers = N alloc + N dealloc + ~30N KVC property copies per frame.

**Recommendation:** Persist presentation layers across frames. Update only changed properties via dirty flags.
- **Effort:** Medium
- **Impact:** Eliminates dominant per-frame allocation cost

### 5.8 Texture Upload

**Current state:** CAGLTexture does full glTexImage2D every frame with per-pixel alpha unpremultiply loop.

**Recommendations:**
1. Cache uploaded textures; only re-upload on content change
2. Use PBO for async upload
3. Fix the divide-by-zero bug on alpha=0 pixels
4. Use glTexSubImage2D for partial updates
- **Effort:** Medium
- **Impact:** Eliminates GPU-side bottleneck for layer composition

---

## 6. Optimization Priority Matrix

### Effort vs Impact

```
                    LOW EFFORT          MEDIUM EFFORT         HIGH EFFORT
                    ─────────────────────────────────────────────────────
HIGH IMPACT    │ Atomic load fix     │ Weak ref striping    │ Per-class cache ver
               │ Cache version align │ NSCache rewrite      │ Small-string tagged ptr
               │ Re-enable expose    │ Timer min-heap       │ Dirty region list
               │ JSON depth limit    │ DPSimage caching     │ Scroll overdraw
               │ CFArray *2 growth   │ Resize throttling    │
               │                     │ Presentation persist │
               │                     │ Theme pre-render     │
               ├─────────────────────┼──────────────────────┤
MEDIUM IMPACT  │ JSON buffer 4096    │ Pool page recycling  │ NSZone removal
               │ JSON integer detect │ Small dict class     │ Mutable inline arrays
               │ CFString geom grow  │ Hash function update │ AArch64 TLS register
               │ Path bbox caching   │ Glyph caching        │
               │                     │ Texture dirty track  │
               ├─────────────────────┼──────────────────────┤
LOW IMPACT     │ msgSend spill fix   │ SMALLOBJ immediate   │ dtable cache-line move
               │ defaultValueForKey  │ Selector list resize │ Non-pointer isa
               │                     │ IMP cache 64-slot    │
```

### Recommended Execution Order

**Sprint 1 (Quick Wins — Low Effort, High Impact):**
1. Replace `__sync_fetch_and_add(x,0)` with `__atomic_load_n` in arc.mm
2. Add `aligned(64)` to `objc_method_cache_version`
3. Re-enable X11 expose event coalescing
4. Add JSON recursion depth limit
5. Change CFArray growth from +16 to *2
6. Increase JSON parser buffer from 64 to 4096

**Sprint 2 (Core Fixes — Medium Effort, High Impact):**
7. Stripe weak reference lock (64-way)
8. Rewrite NSCache with O(1) linked list + proper eviction
9. Replace NSRunLoop timer array with min-heap
10. Cache DPSimage pixel format conversion results
11. Add live resize throttling

**Sprint 3 (Rendering — Medium Effort, High Impact):**
12. Replace NSView single _invalidRect with dirty region list
13. Persist CALayer presentation layers across frames
14. Pre-render themed controls to cached bitmaps
15. Implement scroll content overdraw in NSClipView

**Sprint 4 (Foundation — Medium-High Effort, High Impact):**
16. Implement tagged-pointer NSString for short ASCII
17. Add GSSmallDictionary for <=4 entries
18. Fix CFRunLoop per-iteration malloc (use stack buffers)
19. Implement pool page recycling

**Sprint 5 (Architectural — High Effort, High Impact):**
20. Per-class cache generation counters (replace global version)
21. Move dtable adjacent to isa in class struct (ABI change)
22. Implement dirty region tracking in CALayer rendering pipeline
23. Add glyph caching to CoreText/libs-opal

---

## Benchmark Suite Requirements

To measure the impact of optimizations, the following benchmarks are needed:

| Benchmark | What it Measures | Baseline Tool |
|-----------|-----------------|---------------|
| msg_send_throughput | Messages/sec for cached IMP path | Custom C benchmark |
| retain_release_cycle | Retain/release pairs/sec (single + multi-threaded) | Custom C benchmark |
| weak_ref_contention | Weak ref ops/sec at 1, 2, 4, 8 threads | Custom C benchmark |
| autorelease_drain | Objects/sec through autorelease pool | Custom C benchmark |
| string_hash_throughput | Hash computations/sec for short/medium/long strings | Custom ObjC benchmark |
| dict_lookup_throughput | Dictionary lookups/sec for small (4) and large (10K) dicts | Custom ObjC benchmark |
| json_parse_throughput | MB/sec for representative JSON documents | Custom ObjC benchmark |
| nsrunloop_timer_overhead | Timer fire latency with 1, 10, 100, 1000 timers | Custom ObjC benchmark |
| view_invalidation | Frames/sec with 100 views, varying dirty patterns | GUI benchmark app |
| scroll_performance | Frames/sec scrolling large content | GUI benchmark app |
| image_draw_throughput | Images/sec for various sizes and formats | GUI benchmark app |
| window_resize_fps | Frames/sec during continuous window resize | GUI benchmark app |
| theme_draw_throughput | Themed controls/sec | GUI benchmark app |
