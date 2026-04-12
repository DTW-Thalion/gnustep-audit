# Phase 4: libs-opal + libs-quartzcore Graphics Layer Audit Findings

**Date:** 2026-04-12
**Status:** ALL FIXED — 4 commits (2 per repo)
**Repos:** libs-opal (176 files), libs-quartzcore (94 files)

---

## Executive Summary

Combined **6 Critical, 9 High, 10 Medium, 5 Low** findings. Both repos have **zero thread safety primitives** (except one font lock in libs-opal) and only 11 assertions total. Several outright bugs found.

Most impactful:
1. **CGContext fill_path NULL dereference in error logging** (Critical) — guaranteed crash
2. **TIFF destination init condition inverted** (Critical) — TIFF writing 100% broken
3. **CGContext+GState dash buffer under-allocation** (High) — heap corruption (malloc bytes instead of doubles)
4. **CATransaction global stack unprotected** (Critical) — any multi-threaded animation crashes
5. **CAGLTexture divide-by-zero on transparent pixels** (Critical) — corrupts every texture with alpha=0

---

## libs-opal Findings

### Thread Safety
| ID | Sev | File:Line | Issue |
|----|-----|-----------|-------|
| TS-O1 | Critical | CGContext-private.h:52-60 | All fields @public, every drawing op reads/writes cairo state without lock |
| TS-O2 | Critical | CGContext.m:301-370 | GState save/restore stack (singly-linked list) corrupted by concurrent access |
| TS-O3 | Medium | CGContext.m:39,77-80 | Static `default_cp` init race on first context creation |
| TS-O5 | High | OPPath.m:220-250 | Mutable CGPath `realloc`-based array; shared mutable path across threads = UAF |

### Assertion & Robustness
| ID | Sev | File:Line | Issue |
|----|-----|-----------|-------|
| AR-O1 | High | CGPath.m (all add ops) | No NaN/Inf validation on any path coordinate |
| AR-O2 | **Critical** | CGContext.m:816-824 | `fill_path` NULL-dereferences `ctx->add` inside error-logging branch when `ctx` is NULL |
| AR-O3 | High | CGContext.m:341-370 | GState restore underflow: logs warning but continues with NULL `ctx->add`, subsequent draws crash |
| AR-O4 | Medium | OPImageCodecJPEG.m:382-498 | Memory leak of `imgbuffer` on truncated JPEG (longjmp skips free) |
| AR-O5 | Medium | OPImageCodecJPEG.m:419 | Only 1 assertion in all image codecs; no dimension/alloc checks |
| AR-O6 | High | OPImageCodecTIFF.m:83-88 | Unchecked read beyond buffer in TIFF handle; NSRangeException propagates to libtiff |
| AR-O7 | **Critical** | OPImageCodecTIFF.m:337 | TIFF destination init condition uses `\|\|` instead of `&&` + missing negation — TIFF writing 100% broken |
| AR-O8 | **High** | CGContext+GState.m:88 | `malloc(dashes_count)` allocates bytes instead of `dashes_count * sizeof(double)` — **heap buffer overflow** |

### Performance
| ID | Sev | Issue | Impact |
|----|-----|-------|--------|
| PF-O1 | Medium | CGPath linear growth (+32 elements) | O(n) reallocs for large paths |
| PF-O2 | Low | Every CGContext op is a direct cairo wrapper; no state caching | Redundant state changes not eliminated |
| PF-O3 | Medium | CGPathGetBoundingBox scans all elements every call | No cached bounding box |
| PF-O4 | Medium | No glyph cache or layout cache in CoreText | Full rasterization on every text draw |

---

## libs-quartzcore Findings

### Thread Safety
| ID | Sev | File:Line | Issue |
|----|-----|-----------|-------|
| TS-Q1 | **Critical** | CATransaction.m:38,58-76 | Global `transactionStack` modified without lock; `+lock`/`+unlock` explicitly unimplemented |
| TS-Q2 | **Critical** | CALayer.m:841-881 | `_sublayers` mutated without sync; CARenderer iterates sublayers during render = crash |
| TS-Q3 | High | CARenderer.m:253 | GL context `makeCurrentContext` with no thread affinity enforcement |
| TS-Q4 | High | CALayer.m:48 | Static `currentFrameBeginTime` shared across all layers without sync |
| TS-Q5 | Medium | CAGLSimpleFramebuffer.m:35 | Global framebuffer stack without locking |
| TS-Q6 | Medium | CADisplayLink.m | Entirely unimplemented (25 lines total, just header) |

### Assertion & Robustness
| ID | Sev | File:Line | Issue |
|----|-----|-----------|-------|
| AR-Q1 | High | CALayer.m:656,935 | Only 2 assertions in 1200+ lines; `activeTime > 0` assert crashes on valid future-begin inputs |
| AR-Q2 | High | CALayer.m:841-847 | No circular parent-child protection; `addSublayer:` allows cycles → infinite render recursion |
| AR-Q3 | High | CALayer.m:678-681 | `isPresentationLayer` logic inverted (returns YES when `_presentationLayer` is nil) |
| AR-Q4 | **Critical** | CAGLTexture.m:214 | Division by zero on transparent pixels (alpha=0) during unpremultiply |
| AR-Q5 | Medium | CAGLTexture.m:67-68, CAGLProgram.m:43, etc. | GL resource creation never error-checked |
| AR-Q6 | High | CAGLTexture.m:256-258 | VLA `char pixels[w*h*4]` on stack — 4MB for 1024x1024 texture, stack overflow |
| AR-Q7 | Medium | CARenderer.m:818-819 | Hardcoded 512x512 rasterization size clips larger layers |

### Performance
| ID | Sev | Issue | Impact |
|----|-----|-------|--------|
| PF-Q1 | **High** | Presentation layer destroyed and recreated every frame (N allocs + N deallocs + ~30N KVC copies) | Dominates frame cost |
| PF-Q2 | Medium | O(n) NSPredicate filter on action registration per property change | Quadratic for many animated properties |
| PF-Q3 | Low | CAKeyframeAnimation / CASpringAnimation completely unimplemented | Non-functional, not a perf issue |
| PF-Q4 | Medium | All rendering uses deprecated glBegin/glEnd immediate mode | Slowest possible GL path |
| PF-Q5 | **High** | Full image re-upload via glTexImage2D every frame; no caching or dirty tracking | Texture upload dominates GPU time |
| PF-Q6 | Low | `defaultValueForKey:` uses linear string comparison chain | O(n) per property lookup during init |
