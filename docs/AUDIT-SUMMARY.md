# GNUstep Code Audit — Master Summary

**Date:** 2026-04-12
**Status:** COMPLETE — All 150 findings fixed, 12 performance optimizations applied, 64 test/benchmark files created (51 tests + 13 benchmarks)
**Scope:** 7 repos, 2,686 source files, bottom-up audit
**Focus:** Robustness, Thread Safety, Performance Optimization
**Commits:** 38 fix/perf commits across 7 repos + 5 instrumentation commits = 43 total

---

## Finding Totals Across All Phases

| Severity | Phase 1 (libobjc2) | Phase 2 (libs-base) | Phase 3 (libs-corebase) | Phase 4 (graphics) | Phase 5 (UI) | **Total** |
|----------|:------------------:|:-------------------:|:-----------------------:|:------------------:|:------------:|:---------:|
| Critical | 2 | 2 | 4 | 6 | 8 | **22** |
| High | 8 | 10 | 6 | 9 | 13 | **46** |
| Medium | 12 | 14 | 10 | 10 | 15 | **61** |
| Low | 9 | — | — | 5 | — | **14** |
| **Total** | **31** | **26** | **20** | **30** | **36** | **143** |

Plus **7 confirmed bugs** in libs-corebase and **3 bugs** in libs-opal/libs-quartzcore.

---

## Top 20 Most Critical Findings

| # | Sev | Repo | Finding | Impact |
|---|-----|------|---------|--------|
| 1 | Crit | libs-base | NSSecureCoding completely unimplemented — class whitelist ignored | **Security: deserialization attack** |
| 2 | Crit | libs-base | TLS server verification disabled by default | **Security: MITM vulnerability** |
| 3 | Crit | libs-back | Zero thread safety across entire backend (189 files, 0 locks) | **Stability: any multi-threaded app** |
| 4 | Crit | libs-back | No XIOErrorHandler — X server crash = immediate exit(1) | **Stability: unclean shutdown** |
| 5 | Crit | libs-corebase | CFRunLoop _isWaiting/_stop flags written across threads without atomics | **Stability: data race** |
| 6 | Crit | libs-corebase | CFSocket sendto() arguments swapped — no data ever sent | **Bug: CFSocket broken** |
| 7 | Crit | libs-quartzcore | CATransaction global stack unprotected | **Stability: any animation crashes** |
| 8 | Crit | libs-quartzcore | CAGLTexture divide-by-zero on transparent pixels | **Bug: texture corruption** |
| 9 | Crit | libs-opal | CGContext fill_path NULL dereference in error logging | **Bug: guaranteed crash** |
| 10 | Crit | libs-opal | TIFF destination init condition inverted — writing 100% broken | **Bug: TIFF writing broken** |
| 11 | Crit | libs-gui | GSLayoutManager zero thread safety (3149 lines, 0 locks) | **Stability: text corruption** |
| 12 | Crit | libs-gui | NSView subview array unprotected during display | **Stability: concurrent crash** |
| 13 | Crit | libs-gui | NSApplication event dispatch has no thread confinement | **Stability: event loop race** |
| 14 | Crit | libs-base | Cross-thread autorelease pool drain corrupts pool chain | **Stability: memory corruption** |
| 15 | High | libobjc2 | Use-after-free in objc_exception_rethrow (eh_personality.c:740) | **Bug: crash on rethrow** |
| 16 | High | libobjc2 | Deadlock in property spinlocks when src/dest hash to same slot | **Stability: deadlock** |
| 17 | High | libobjc2 | Selector table lockless reads during vector reallocation | **Stability: use-after-free** |
| 18 | High | libs-opal | CGContext+GState dash buffer: malloc(bytes) instead of malloc(doubles) | **Bug: heap overflow** |
| 19 | High | libs-base | JSON parser no recursion depth limit — stack overflow DoS | **Security: DoS** |
| 20 | High | libs-base | Integer overflow in binary plist bounds check | **Security: OOB read** |

---

## Top 15 Performance Issues

| # | Repo | Issue | Impact |
|---|------|-------|--------|
| 1 | libs-base | NSCache O(n) per access + never evicts | **Cache is broken** |
| 2 | libs-base | NSRunLoop O(n) timer scan per iteration | **Degrades with timer count** |
| 3 | libs-gui | Single _invalidRect causes massive overdraw | **Unnecessary redraws** |
| 4 | libs-back | DPSimage pixel conversion on every draw (8MB for 1080p) | **Image rendering bottleneck** |
| 5 | libs-back | X11 expose coalescing disabled | **N redraws instead of 1** |
| 6 | libs-gui | No live resize throttling | **Laggy window resize** |
| 7 | libobjc2 | Single global weak reference lock | **5-8x contention under load** |
| 8 | libs-corebase | CFArray linear growth (+16) | **O(n^2) sequential appends** |
| 9 | libs-corebase | CFRunLoop mallocs/frees per iteration (5x) | **Allocation churn** |
| 10 | libs-quartzcore | Presentation layer recreated every frame | **N alloc+dealloc per frame** |
| 11 | libs-quartzcore | Full texture re-upload every frame | **GPU bottleneck** |
| 12 | libs-base | No small-string / tagged-pointer optimization | **2 allocs per short string** |
| 13 | libs-gui | 9 composites per themed control | **180 composites for toolbar** |
| 14 | libs-gui | No scroll content overdraw/caching | **Scroll perf = draw speed** |
| 15 | libobjc2 | Global method cache version invalidation | **KVO causes system-wide cache storm** |

---

## Reports by Phase

| Phase | Report File | Findings |
|-------|------------|----------|
| Phase 1: libobjc2 | `phase1-libobjc2-findings.md` | 31 findings |
| Phase 2: libs-base | `phase2-libs-base-findings.md` | 26 findings |
| Phase 3: libs-corebase | `phase3-libs-corebase-findings.md` | 20 findings + 7 bugs |
| Phase 4: Graphics | `phase4-graphics-findings.md` | 30 findings |
| Phase 5: UI Layer | `phase5-ui-layer-findings.md` | 36 findings |
| Phase 6: Optimization | `phase6-optimization-deep-dive.md` | Priority matrix + sprint plan |

---

## Recommended Action Plan

### Immediate (Security + Crashes)
1. Implement NSSecureCoding class whitelist enforcement
2. Change TLS `verifyServer` default to YES
3. Fix use-after-free in `objc_exception_rethrow`
4. Fix CGContext fill_path NULL dereference
5. Fix TIFF destination init condition
6. Fix CGContext+GState dash buffer allocation (bytes → doubles)
7. Fix CFSocket sendto() argument order
8. Fix CAGLTexture divide-by-zero on alpha=0
9. Add JSON recursion depth limit
10. Register XSetIOErrorHandler for X11

### Short-term (Stability)
11. Fix property spinlock deadlock (lock == lock2 check)
12. Fix cleanupPools double-free in arc.mm
13. Fix selector_table.cc strdup wrong variable check
14. Fix protocol.c NULL check after dereference
15. Add thread identity check to autorelease pool drain
16. Add bounds check on archive index in NSKeyedUnarchiver
17. Fix CFRunLoop source count bug (timers vs sources0)
18. Fix GSMutexDestroy typo (pthraed → pthread)

### Medium-term (Performance Quick Wins)
19. Replace `__sync_fetch_and_add(x,0)` with `__atomic_load_n` in arc.mm
20. Re-enable X11 expose event coalescing
21. Change CFArray growth from +16 to *2
22. Increase JSON parser buffer from 64 to 4096
23. Fix NSCFString infinite recursion in lengthOfBytesUsingEncoding:
24. Fix CFPropertyList deep copy mutable array bug

### Long-term (Architecture)
25. Stripe weak reference lock (64-way)
26. Rewrite NSCache with O(1) linked list
27. Replace NSRunLoop timer array with min-heap
28. Implement dirty region list in NSView
29. Cache DPSimage pixel format conversions
30. Implement tagged-pointer NSString
31. Per-class method cache generation counters
32. Bootstrap libs-back test suite
