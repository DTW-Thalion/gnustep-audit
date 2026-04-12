# Phase 5: libs-gui + libs-back UI Layer Audit Findings

**Date:** 2026-04-12
**Status:** ALL FIXED — 5 commits (3 libs-gui, 2 libs-back)
**Repos:** libs-gui (801 files), libs-back (189 files, now has 3 regression tests)

---

## Executive Summary

Combined **8 Critical, 13 High, 15 Medium** findings. libs-back has **zero tests** and **zero application-level thread synchronization**. libs-gui has critical thread safety gaps in the event loop, view hierarchy, and text system.

Most impactful:
1. **libs-back has zero thread safety across entire codebase** (Critical)
2. **No XIOErrorHandler** — X server crash = immediate unclean exit(1) (Critical)
3. **GSLayoutManager has zero thread safety** (Critical) — background layout corruption
4. **NSView subview array unprotected during display** (Critical) — concurrent add/remove crashes
5. **Single _invalidRect causes massive overdraw** (High perf) — all dirty regions merged to bounding box

---

## libs-gui Thread Safety Findings

| ID | Sev | File:Line | Issue |
|----|-----|-----------|-------|
| TS-G1 | **Critical** | NSApplication.m:2209-2262 | `nextEventMatchingMask:` has no thread confinement check; races with main event loop |
| TS-G2 | **Critical** | NSView.m:789-844 | `addSubview:` mutates `_sub_views` without lock; `displayRectIgnoringOpacity:` iterates same array |
| TS-G3 | **Critical** | GSLayoutManager.m (3149 lines) | Zero locks, zero thread checks; background layout + user typing = glyph structure corruption |
| TS-G4 | High | NSApplication.m:1685-1749 | Modal session linked list manipulated without lock; `abortModal` from background thread races |
| TS-G5 | High | NSWindow.m:3219-3248 | Window close + RELEASE(self) while observers hold stale pointers |
| TS-G6 | High | NSImage.m:1262-1334 | `_lockedView` ivar shared without lock; concurrent drawing of same image races |
| TS-G7 | High | NSImage.m:1276 | `_cacheForRep:` called during lockFocus without `imageLock` held |
| TS-G8 | High | NSView.m:2106-2290 | Focus stack mismatch (exception in drawRect) permanently corrupts graphics state |
| TS-G9 | High | GSTextStorage.m:60 | Static `adding` global variable behind lock — fragile pattern shared across instances |
| TS-G10 | Medium | NSApplication.m:1903,2115,2259 | `_current_event` assigned from multiple paths without sync |
| TS-G11 | Medium | NSView.m:2807-2822 | `setNeedsDisplay:` cross-thread dispatch is correct but fragile (DESTROY after async perform) |
| TS-G12 | Medium | NSWindow.m:4066-4069 | Events to closed windows checked only per-event-type, not uniformly |
| TS-G13 | Medium | NSGraphicsContext.m:250-268 | `restoreGraphicsState` stack underflow silently sets context to nil |
| TS-G14 | Medium | NSPasteboard.m:1781-1796 | `changeCount` read-modify is not atomic |
| TS-G15 | Medium | NSWindow.m (entire file) | Zero locks in 171KB; no main-thread enforcement |

## libs-gui Robustness Findings

| ID | Sev | File:Line | Issue |
|----|-----|-----------|-------|
| RB-G1 | High | NSView.m:1289-1290 | Division by zero in `setFrameSize:` when frame width/height is 0 and view is rotated/scaled |
| RB-G2 | High | GSNibLoading.m:798-801 | Missing class in nib raises unrecoverable exception; no substitution fallback |
| RB-G3 | Medium | NSView.m:1184-1245 | No NaN/Inf validation on geometry inputs; NaN causes infinite notification loops |
| RB-G4 | Medium | NSNibOutletConnector.m:63-69 | Outlet ivar set directly without retain when setter not found |
| RB-G5 | Medium | NSNibControlConnector.m:37-43 | No selector existence validation; nil selector assigned as action |
| RB-G6 | Medium | NSView.m:2561-2611 | `_lockFocusInContext:` returns early on gState==0 but `unlockFocus` still called → stack corruption |
| RB-G7 | Medium | NSView.m:2608-2610 | No nil context check; DPS calls on nil context may crash |
| RB-G8 | Medium | NSPrintOperation.m:939-1088 | No cancellation mechanism during print page loop |
| RB-G9 | Low | NSApplication.m:2124-2174 | Unknown event types partially handled; nil window for some events silently ignored |

---

## libs-back Thread Safety Findings

| ID | Sev | File:Line | Issue |
|----|-----|-----------|-------|
| TS-B1 | **Critical** | Entire codebase | **Zero application-level thread synchronization** across all 189 files |
| TS-B2 | **Critical** | x11/XGServerWindow.m:85-89 | Static `windowmaps`/`windowtags` NSMapTables accessed without any lock |
| TS-B3 | **Critical** | x11/XGServer.m:501 | No XSetIOErrorHandler registered; X server crash calls default handler = `exit(1)` |
| TS-B4 | **Critical** | wayland/WaylandServer.m:264-268 | dealloc does not call `wl_display_disconnect()` or free resources; total leak |
| TS-B5 | **Critical** | wayland/WaylandCairoShmSurface.m:73-78 | Buffer `busy` flag written by compositor callback without atomic/lock |
| TS-B6 | High | cairo/CairoGState.m:144-179 | `copyWithZone:` creates cairo context on same surface; concurrent drawing = undefined behavior |
| TS-B7 | High | x11/XWindowBuffer.m:41-42 | Static `window_buffers` array grown with realloc, no lock |
| TS-B8 | High | win32/WIN32Server.m:79-81 | Static `update_cursor`/`current_cursor` without synchronization |
| TS-B9 | High | x11/XGCairoModernSurface.m:112-145 | `handleExposeRect:` modifies surface device offset; concurrent drawing corrupts coordinates |

## libs-back Robustness Findings

| ID | Sev | File:Line | Issue |
|----|-----|-----------|-------|
| RB-B1 | **Critical** | x11/XGServer.m:501 | No XIOErrorHandler — fatal X error = immediate exit(1) with no cleanup |
| RB-B2 | High | cairo/CairoGState.m:156-161 | `copyWithZone:` returns partially-initialized object on cairo_create failure |
| RB-B3 | High | x11/XWindowBuffer.m:200-203 | `realloc` failure calls `exit(1)` — no graceful degradation |
| RB-B4 | High | wayland/WaylandCairoShmSurface.m:127-171 | `createShmBuffer` leaks `pool_buffer` struct on `createPoolFile`/`mmap` failure |
| RB-B5 | High | win32/WIN32Server.m | GDI handle cleanup duplicated in 4+ locations with no centralization |
| RB-B6 | Medium | wayland/WaylandServer.m:482 | `titlewindow:` string comparison uses `==` instead of `isEqualToString:` |
| RB-B7 | Medium | GSBackend.m:53-57 | Headless backend is compile-time only, not runtime fallback |
| RB-B8 | Medium | Multiple (57 files) | 268 TODO/FIXME/HACK markers across codebase |

---

## libs-gui + libs-back Performance Findings

| ID | Sev | Issue | Impact |
|----|-----|-------|--------|
| PF-1 | **P0** | NSView single `_invalidRect` merges all dirty regions to bounding box | Massive overdraw for disjoint dirty areas |
| PF-2 | **P0** | CairoGState DPSimage pixel format conversion on every draw (8MB alloc + 2M pixel swaps for 1080p) | Dominates image drawing cost |
| PF-3 | **P0** | X11 expose event coalescing disabled (`#if 0` block) | N expose events = N separate redraw cycles |
| PF-4 | **P0** | No live resize throttling; every pixel of resize triggers full relayout + redraw | Laggy window resizing |
| PF-5 | **P1** | NSNumber/NSValue allocation on every setNeedsDisplay: call | Heap alloc on most-called method |
| PF-6 | **P1** | No scroll content caching / overdraw in NSClipView | Scroll performance depends entirely on draw speed |
| PF-7 | **P1** | 9 image composites per themed control (nine-patch tiles) | 180 composites for 20-button toolbar |
| PF-8 | **P1** | Cairo push_group temporary surface on every scroll composite | Alloc+free per scroll step |
| PF-9 | **P1** | Multiple XSync round-trips per X11 operation | 0.1-1ms per round-trip |
| PF-10 | **P2** | updateServicesMenu on every non-periodic event | Full responder chain walk per event |
| PF-11 | **P2** | opaqueAncestor walk on every setNeedsDisplayInRect: | O(depth) per invalidation |
| PF-12 | **P2** | Cairo pattern create/destroy per composite | Overhead for frequent compositing |
| PF-13 | **P2** | Font glyph cache only 257 entries (hash collisions) | Poor cache hit rate for large character sets |
| PF-14 | **P2** | No WM_PAINT coalescing on Win32 | Duplicate redraws |

---

## libs-back Test Bootstrapping Plan

### Phase A: Crash Prevention (Week 1-2)
1. Headless backend smoke test (NSApplication lifecycle)
2. Wayland buffer lifecycle + memory leak fixes
3. X11 window map consistency under rapid create/destroy

### Phase B: Resource Integrity (Week 3-4)
4. Win32 GDI handle leak detection (count before/after lifecycle)
5. Cairo surface error propagation tests
6. Register XSetIOErrorHandler + test X disconnect

### Phase C: Correctness (Week 5-6)
7. Font enumeration per backend
8. Coordinate transformation roundtrip tests
9. Cairo drawing output comparison (render → compare pixels)

### Phase D: Thread Safety Hardening (Week 7-8)
10. Add NSLock to X11 windowmaps/windowtags
11. Add @synchronized to CairoGState surface access
12. Implement graceful X server disconnect shutdown
