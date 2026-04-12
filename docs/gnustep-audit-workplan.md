# GNUstep End-to-End Code Audit Workplan

**Scope:** Core runtime + UI stack (7 repos, ~2,686 source files)
**Approach:** Bottom-up — runtime first, then foundation, then UI layers
**Focus Areas:** Robustness (assertions, error handling), Thread Safety, Performance Optimization
**Date:** 2026-04-12

---

## Repos In Audit Order

| Layer | Repo | Files | Primary Language | Role |
|-------|------|------:|------------------|------|
| 0 - Runtime | libobjc2 | 150 | C/Obj-C/ASM | Objective-C runtime, message dispatch |
| 1 - Foundation | libs-base | 1,123 | Obj-C/C | Foundation framework (NSString, NSArray, NSThread, etc.) |
| 1 - Foundation | libs-corebase | 153 | C/Obj-C | CoreFoundation C layer, toll-free bridging |
| 2 - Graphics | libs-opal | 176 | Obj-C/C | CoreGraphics/Quartz 2D on Cairo |
| 2 - Graphics | libs-quartzcore | 94 | Obj-C | Core Animation (CALayer, CATransaction) |
| 3 - UI | libs-gui | 801 | Obj-C | AppKit (NSView, NSWindow, NSApplication) |
| 3 - UI | libs-back | 189 | Obj-C/C | Display backends (Win32, X11, Cairo) |

---

## Phase 1: libobjc2 — Runtime Audit

The runtime underpins everything. Bugs here cause mysterious crashes across the entire stack.

### 1.1 Thread Safety Audit

**Priority: CRITICAL**

Current state: 16 locking occurrences across 3 files. Uses `pthread_mutex_t`, `CRITICAL_SECTION` (Windows), `LOCK_RUNTIME()` / `LOCK_FOR_SCOPE()` macros, and `RecursiveMutex` C++ wrapper.

| Task | Files | What to Check |
|------|-------|---------------|
| Runtime lock granularity | `lock.h`, `properties.cc`, `loader.cc` | Verify `LOCK_RUNTIME()` scope is minimal; identify lock contention under concurrent class loading |
| Dispatch table initialization races | `dtable.c`, `dtable.h` | Temporary dtable chain during `+initialize` — verify ordering guarantees when multiple threads trigger class init simultaneously |
| Selector table concurrency | `selector_table.cc` | Uses `std::mutex` + robin_set. Audit insert/lookup races under concurrent selector registration |
| Class table concurrent access | `class_table.c` | Hash-based lookup with 3 assertions. Verify thread-safe registration of dynamically created classes |
| ARC fast paths | `arc.mm` (28 KB) | Autorelease pool thread-local storage, weak reference table locking, concurrent retain/release paths |
| Atomic CAS operations | `objc-auto.h` | 8 `objc_atomicCompareAndSwap*` variants — verify memory ordering (seq_cst vs. relaxed), ABI correctness |
| Spinlock contention | `spinlock.h` | Verify spinlocks don't starve threads under contention; check for priority inversion risk |

### 1.2 Assertion & Robustness Audit

Current state: 551 assertions, 75 files. Heavy in dispatch chain and test suite.

| Task | Files | What to Check |
|------|-------|---------------|
| Non-test assertion coverage | Core `.c`/`.mm` files (exclude `Test/`) | Map which production code paths lack assertions for invariant violations |
| `abort()` / crash paths | All source | Identify ungraceful termination paths; determine if recovery is possible vs. required |
| NULL dereference guards | `sendmsg2.c`, `arc.mm`, `dtable.c` | Verify nil receiver handling in all dispatch paths (not just objc_msgSend) |
| Exception propagation | `eh_personality.c`, `exception.cc` | Verify C++/Obj-C exception interop, stack unwinding correctness on all platforms |
| Category loading order | `loader.cc` | Verify categories applied after class is fully initialized; check for partial-init visibility |

### 1.3 Performance Optimization

**This layer has the highest multiplier — every message send in every GNUstep app passes through here.**

| Task | Files | What to Check |
|------|-------|---------------|
| Message dispatch hot path | `sendmsg2.c`, `objc_msgSend.*.S` (x86-32, x86-64, aarch64, arm, mips, riscv64) | Profile cache hit/miss ratio; verify IMP caching is optimal; check branch prediction alignment in assembly |
| Dtable sparse array lookups | `dtable.c` | Sparse array depth vs. flat table tradeoff; measure lookup latency for deep class hierarchies |
| Selector lookup performance | `selector_table.cc` | robin_set hash collision rates; memory layout for cache-line alignment |
| ARC retain/release fast path | `arc.mm` | Inline refcount overflow/underflow paths; tagged pointer optimization; side-table lookup frequency |
| Autorelease pool drain cost | `arc.mm` | Pool page allocation strategy; per-thread pool stack depth; drain latency under heavy allocation |
| Class lookup / isa optimization | `class_table.c`, `objc-auto.h` | Non-pointer isa usage; class table hash function quality |
| Memory layout / cache lines | All hot-path structs | Verify frequently accessed struct fields are in the same cache line; check for false sharing |

### 1.4 Deliverables

- [ ] Thread safety findings report with severity ratings
- [ ] List of missing assertions with recommended additions
- [ ] Benchmark suite for message dispatch, retain/release, autorelease drain
- [ ] Patch set for identified issues (separate branches per category)

---

## Phase 2: libs-base — Foundation Audit

The largest codebase (1,123 files). Contains every Foundation class. 656 locking occurrences, 568 assertions.

### 2.1 Thread Safety Audit

**Priority: CRITICAL**

Current state: Threading abstracted through `GSPThread.h`. Uses NSLock, NSRecursiveLock, NSConditionLock, NSCondition, SRWLOCK (Windows), pthread primitives (POSIX).

| Task | Files | What to Check |
|------|-------|---------------|
| Lock hierarchy analysis | All files using NSLock/pthread | Map lock acquisition ordering across all subsystems; identify potential deadlock cycles |
| NSAutoreleasePool thread safety | `NSAutoreleasePool.m` (19 KB) | Pool scope vs. thread lifetime; verify no cross-thread pool drain; check for pool exhaustion under high allocation |
| NSRunLoop concurrency | `NSRunLoop.m` (43 KB) | Timer scheduling from background threads; source addition/removal during runloop iteration; mode switching races |
| NSThread lifecycle | `NSThread.m` (69 KB) | Thread-local storage cleanup; thread cancellation safety; join/detach correctness |
| NSOperation queue management | `NSOperation.m` (32 KB) | Operation dependency resolution under concurrent modification; KVO notifications from operation threads |
| NSNotificationCenter thread safety | `NSNotificationCenter.m` | Observer add/remove during notification dispatch; cross-thread posting guarantees |
| Distributed Objects | `NSDistantObject.m`, `NSConnection.m` | RPC serialization under concurrent calls; connection lifecycle vs. proxy lifetime |
| GSPThread.h abstraction correctness | `GSPThread.h` | Verify Windows SRWLOCK semantics match POSIX pthread behavior; check `_Atomic(DWORD) owner` correctness |
| Collection mutation during enumeration | `NSArray.m`, `NSDictionary.m`, `NSSet.m` | Mutation tracking correctness; verify exceptions raised on concurrent modification |

### 2.2 Assertion & Robustness Audit

Current state: 568 assertions across 108 files. Heavy in NSZone (61), NSException.h (69), NSLock (52).

| Task | Files | What to Check |
|------|-------|---------------|
| NSZone memory management | `NSZone.m` (61 assertions) | Zone-based allocation safety; verify malloc zone exhaustion handling; check zone reuse after destroy |
| NSException paths | `NSException.m`, `NSException.h` | Verify all uncaught exception handlers are invoked; stack trace capture reliability; re-raise semantics |
| NSCoding / archiving robustness | `NSKeyedArchiver.m`, `NSKeyedUnarchiver.m` | Malformed archive handling; type mismatch recovery; class substitution attack surface |
| Network error handling | `GSHTTPURLHandle.m`, `GSTLS.m`, `NSURLSession` | TLS handshake failure recovery; timeout handling; partial read/write recovery; certificate validation |
| Property list parsing | `NSPropertyList.m`, `NSJSONSerialization.m` | Malformed input handling; integer overflow on numeric parsing; deeply nested structure stack overflow |
| File I/O edge cases | `NSFileManager.m`, `NSFileHandle.m` | Permission denied recovery; symlink loop detection; large file handling; interrupted syscall retry |
| Type encoding validation | `NSMethodSignature.m`, `NSInvocation.m` | Malformed type string handling; buffer overflow risk in encoding parsing |

### 2.3 Performance Optimization

**Foundation classes are called millions of times per app lifecycle. Even micro-optimizations compound.**

| Task | Files | What to Check |
|------|-------|---------------|
| NSString optimization | `NSString.m` (194 KB) | Encoding conversion caching; small-string optimization; hash computation cost; compare/search fast paths |
| NSArray / NSDictionary hot paths | `NSArray.m` (73 KB), `NSDictionary.m` (44 KB) | Inline storage for small collections; hash table load factor; enumeration overhead; objectAtIndex: bounds check cost |
| NSCache eviction performance | `NSCache.m` (8 KB) | Eviction algorithm efficiency; cost tracking overhead; concurrent access patterns |
| NSAutoreleasePool drain frequency | `NSAutoreleasePool.m` (19 KB) | Pool page sizing; drain cost under various allocation patterns; nested pool overhead |
| NSRunLoop latency | `NSRunLoop.m` (43 KB) | Timer coalescing; idle wake frequency; source dispatch overhead; mode switching cost |
| Key-Value Observing overhead | KVO implementation files | Observer registration cost; change notification dispatch overhead; dependency key resolution caching |
| NSData / NSMutableData | `NSData.m` | Copy-on-write implementation; mmap usage for large data; growth factor for mutable data |
| Serialization performance | `NSJSONSerialization.m`, `NSPropertyList.m` | Parse/emit throughput; memory allocation patterns during serialization |

### 2.4 Deliverables

- [ ] Lock hierarchy diagram with deadlock risk annotations
- [ ] Robustness findings with crash reproduction steps where possible
- [ ] Benchmark suite for collections, NSString, NSRunLoop, serialization
- [ ] Patch set organized by subsystem

---

## Phase 3: libs-corebase — CoreFoundation Audit

Toll-free bridging layer. 153 files, only 2 assertions, 14 locking occurrences. **The assertion gap is alarming.**

### 3.1 Thread Safety Audit

| Task | Files | What to Check |
|------|-------|---------------|
| CFRunLoop dispatch safety | `CFRunLoop.c` | Source/timer add/remove during dispatch; cross-thread runloop wake; mode transition atomicity |
| CFSocket concurrent access | `CFSocket.c` (has pthread_mutex) | Socket invalidation during callback; concurrent read/write scheduling |
| Toll-free bridging retain/release | `NSCFString.m`, `NSCFArray.m` | Verify retain/release semantics are identical on both CF and NS sides; check for reference count divergence |

### 3.2 Assertion & Robustness Audit

**Priority: HIGH — only 2 assertions in 153 files is a significant robustness gap.**

| Task | Files | What to Check |
|------|-------|---------------|
| Add defensive assertions | All CF*.c files | NULL parameter checks, type validation, range checks on all public CF API entry points |
| CFPropertyList malformed input | `CFPropertyList.c` (66 ops) | Fuzzing strategy for malformed plists; integer overflow; deeply nested structures |
| CFString encoding edge cases | `CFString.c` (81 ops) | Invalid encoding handling; surrogate pair validation; buffer overrun on encoding conversion |
| GSHashTable invariants | `GSHashTable.c` (has the 2 assertions) | Hash collision handling; resize atomicity; tombstone management |

### 3.3 Performance Optimization

| Task | Files | What to Check |
|------|-------|---------------|
| Toll-free bridging overhead | All NSCFxxx.m bridge files | Measure overhead of CF<->NS transitions; identify unnecessary bridging in hot paths |
| CFString allocation patterns | `CFString.c` | Immutable string interning; buffer reuse; small-string fast path |
| CFArray / CFDictionary | `CFArray.c`, `CFDictionary.c` | Growth strategy; hash quality; inline storage for small counts |
| CFRunLoop wake latency | `CFRunLoop.c` | Wakeup pipe/port overhead; timer resolution; source scan cost |

### 3.4 Deliverables

- [ ] Assertion addition plan (prioritized by API surface exposure)
- [ ] Thread safety findings for CFRunLoop and CFSocket
- [ ] Toll-free bridging overhead measurements
- [ ] Patch set for assertion additions and performance fixes

---

## Phase 4: libs-opal + libs-quartzcore — Graphics Layer Audit

Combined: 270 files, **zero thread safety primitives**, 11 total assertions. These layers are effectively unprotected.

### 4.1 Thread Safety Audit

**Priority: CRITICAL — zero locking in both repos.**

| Task | Files | What to Check |
|------|-------|---------------|
| CGContext thread confinement | `CGContext.m` (27 ops) | Document and enforce single-thread-per-context invariant; add debug assertions for cross-thread access |
| CGPath concurrent construction | `CGPath.m` (111 ops) | Verify path objects are either immutable-after-creation or protected; mutable path sharing risks |
| CALayer property mutation | `CALayer.m` (33 ops) | Implicit animations on property set; concurrent layer tree modification during rendering |
| CATransaction commit safety | `CATransaction.m` | Nested transaction semantics; commit during render pass; cross-thread transaction scope |
| CARenderer concurrent composition | `CARenderer.m` (39 ops) | GL context sharing; texture upload during render; layer tree snapshot consistency |
| CADisplayLink timing | `CADisplayLink.m` | Frame callback reentrancy; display link invalidation during callback |

### 4.2 Assertion & Robustness Audit

| Task | Files | What to Check |
|------|-------|---------------|
| CGPath operation validation | `CGPath.m` | Invalid geometry (NaN, Inf coordinates); empty path operations; path closure invariants |
| CGContext state stack | `CGContext.m` | Save/restore stack overflow; invalid graphics state transitions; NULL context operations |
| Image codec error handling | JPEG/PNG/TIFF codecs in libs-opal | Malformed image data; truncated files; corrupt header handling; memory allocation failures |
| CALayer tree invariants | `CALayer.m` | Circular parent-child references; layer removal during animation; nil superlayer operations |
| GL resource lifecycle | `CAGLTexture`, `CAGLProgram`, `CAGLShader` | Texture/shader deletion during use; GL context loss recovery; resource leak on error paths |

### 4.3 Performance Optimization

| Task | Files | What to Check |
|------|-------|---------------|
| CGPath construction hot path | `CGPath.m` (111 ops — highest density) | Path element storage layout; avoid per-element allocation; batch path operations |
| CGContext state caching | `CGContext.m` | Redundant state changes (color, transform, clip); lazy state application |
| Cairo abstraction overhead | Cairo wrapper files in libs-opal | Measure indirection cost of Opal->Cairo; identify unnecessary wrapper allocations |
| Font rasterization caching | `CTFont.m`, `CTFrame.m` | Glyph cache hit rate; font descriptor reuse; layout caching for repeated text |
| CALayer rendering pipeline | `CALayer.m`, `CARenderer.m`, `CABackingStore.m` | Dirty region tracking; avoid full-layer recomposition; offscreen render elimination |
| Animation interpolation | `CAAnimation.m` (24 ops) | Keyframe interpolation efficiency; timing function evaluation cost; property animation batching |
| Texture upload optimization | `CAGLTexture.m` | Pixel format conversion cost; PBO usage for async upload; texture atlas opportunities |

### 4.4 Deliverables

- [ ] Thread confinement enforcement strategy document
- [ ] Assertion addition plan for both repos
- [ ] Rendering pipeline benchmark (path construction, layer composition, animation frame time)
- [ ] Patch set for thread safety annotations and performance fixes

---

## Phase 5: libs-gui + libs-back — UI Layer Audit

The application-facing layer. libs-gui: 801 files, 73 locking hits, 91 assertions, 35 tests. libs-back: 189 files, **1 locking hit**, 73 assertions, **0 tests**.

### 5.1 Thread Safety Audit

| Task | Files | What to Check |
|------|-------|---------------|
| NSApplication event loop | `NSApplication.m` (128 KB) | Event dispatch from non-main threads; modal session reentrancy; `nextEventMatchingMask:` thread confinement |
| NSView hierarchy mutation | `NSView.m` (145 KB) | `addSubview:` / `removeFromSuperview` during display; `setNeedsDisplay:` from background threads; drawing lock scope |
| NSWindow lifecycle | `NSWindow.m` (171 KB) | Window creation/destruction thread safety; ordering operations during close; delegate callbacks from unexpected threads |
| NSGraphicsContext thread-local | `NSGraphicsContext.m` | Context stack per-thread correctness; `currentContext` after thread pool reuse; focus stack integrity |
| NSPasteboard concurrency | `NSPasteboard.m` | Pasteboard read/write from multiple threads; lazy data provider callbacks; pasteboard change count atomicity |
| NSImage thread safety | `NSImage.m` | Image representation caching; concurrent drawing of same image; lock scope during rep loading |
| Text system concurrency | `NSLayoutManager.m`, `GSTextStorage.m`, `NSTextView.m` | Layout computation on background thread; text storage mutation during layout; glyph cache invalidation |
| Backend single-thread invariant | All libs-back source | **Document and enforce** that backend calls must originate from main thread; add debug assertions |
| Win32 backend event handling | `libs-back/Source/win32/` | Window message pump threading; GDI object access from multiple threads; HBITMAP lifecycle |

### 5.2 Assertion & Robustness Audit

| Task | Files | What to Check |
|------|-------|---------------|
| NSView geometry invariants | `NSView.m` (13 assertions) | Zero-size frame handling; infinite/NaN rect operations; negative dimensions |
| NSNib / XIB loading | Nib loading files | Missing outlet/action connections; class-not-found fallbacks; malformed nib data |
| Event handling edge cases | `NSEvent.m`, `NSApplication.m` | Unknown event types; events after window close; drag events with nil pasteboard |
| Drawing context validity | All drawing code in libs-gui | Draw calls outside `drawRect:` / locked focus; nil graphics context |
| Backend crash recovery | All libs-back source | X11 connection loss; display server crash; GPU driver errors; headless fallback |
| Printing subsystem | Printing/ directory in libs-gui | Print job cancellation; missing printer; paper size mismatch |

### 5.3 Performance Optimization

| Task | Files | What to Check |
|------|-------|---------------|
| Event loop latency | `NSApplication.m`, `NSRunLoop` integration | Event coalescing (mouse moved, resize); idle CPU usage; timer resolution |
| View drawing optimization | `NSView.m` | Dirty rect coalescing; `needsDisplay` propagation cost; opaque view optimization; clipping |
| Scroll performance | `NSScrollView.m`, `NSClipView.m` | Tile-based scrolling; content caching during scroll; live resize performance |
| Text layout caching | `NSLayoutManager.m`, `NSHorizontalTypesetter.m` | Glyph generation caching; line fragment reuse; incremental layout after small edits |
| Image rendering pipeline | `NSImage.m`, `NSBitmapImageRep.m` | Image scaling quality vs. speed; representation caching; draw-in-rect overhead |
| Backend rendering | `libs-back/Source/x11/`, `cairo/`, `win32/` | Surface caching; avoid redundant clears; batch drawing operations; reduce X11 round-trips |
| Window resize performance | `NSWindow.m`, backend resize handlers | Live resize frame rate; subview relayout cost; backing store resize strategy |
| Theme rendering overhead | Theme drawing code | Cache themed control appearances; avoid re-rendering static controls |

### 5.4 Deliverables

- [ ] Main-thread invariant enforcement strategy for libs-back
- [ ] Test suite bootstrapping plan for libs-back (currently 0 tests)
- [ ] Event loop and drawing benchmark suite
- [ ] View hierarchy stress test (deep nesting, rapid mutation)
- [ ] Patch set organized by subsystem

---

## Phase 6: Runtime Optimization Deep Dive

**Cross-cutting performance work informed by findings from Phases 1-5.**

### 6.1 Message Dispatch Optimization

| Task | Scope | Goal |
|------|-------|------|
| Profile IMP cache hit rates | libobjc2 dispatch path | Establish baseline; target >99% cache hit rate for steady-state apps |
| Evaluate inline caching | `sendmsg2.c`, assembly stubs | Compare current strategy against polymorphic inline cache (PIC) approaches |
| Branch prediction optimization | `objc_msgSend.*.S` | Align hot-path branches for prediction; minimize conditional branches in fast path |
| Superclass dispatch optimization | `sendmsg2.c` | Reduce super message send overhead; cache super IMP separately |
| Tagged pointer expansion | `arc.mm`, `sendmsg2.c` | Identify additional types eligible for tagged pointer optimization (NSDate, small NSData) |

### 6.2 Memory Management Optimization

| Task | Scope | Goal |
|------|-------|------|
| Autorelease pool page sizing | libobjc2 `arc.mm`, libs-base `NSAutoreleasePool.m` | Right-size pool pages to minimize waste; measure drain latency vs. page count |
| Retain/release elision | libobjc2 ARC paths | Identify retain/release pairs that can be elided by the optimizer; add `__attribute__((ns_returns_retained))` where missing |
| Weak reference table optimization | libobjc2 `arc.mm` | Profile weak ref lookup cost; evaluate alternative data structures (concurrent hash map) |
| NSZone removal assessment | libs-base `NSZone.m` | Measure overhead of zone-based allocation vs. system malloc; recommend zone elimination where safe |
| Object allocation fast path | libobjc2 + libs-base | Profile `+alloc` / `-init` cost; evaluate pre-zeroed allocation; class-specific allocators for hot types |

### 6.3 Collection Optimization

| Task | Scope | Goal |
|------|-------|------|
| Small collection inline storage | libs-base NSArray, NSDictionary, NSSet | Implement stack-allocated storage for collections with <= 4-8 elements |
| Hash function quality | libs-base NSDictionary, NSSet, libs-corebase CFDictionary | Measure hash distribution; evaluate SipHash or wyhash vs. current hash |
| Enumeration fast path | All collection classes | Reduce per-element overhead in `NSFastEnumeration`; batch element access |
| NSString hash caching | libs-base `NSString.m` | Cache hash values for immutable strings; measure impact on dictionary lookup |
| Copy-on-write for immutable collections | libs-base | Avoid deep copy when creating immutable copy of immutable collection |

### 6.4 I/O and Networking Optimization

| Task | Scope | Goal |
|------|-------|------|
| NSRunLoop source dispatch | libs-base `NSRunLoop.m` | Reduce per-source overhead; batch source checks; use epoll/kqueue where available |
| NSURLSession connection pooling | libs-base NSURLSession | Measure connection reuse rate; optimize TLS session resumption |
| File I/O buffering | libs-base NSFileHandle, NSData | Evaluate read-ahead strategies; mmap threshold tuning; write coalescing |
| Serialization throughput | libs-base JSON, plist serialization | Streaming parse/emit; reduce intermediate allocations; SIMD for JSON string scanning |

### 6.5 Rendering Pipeline Optimization

| Task | Scope | Goal |
|------|-------|------|
| Dirty region coalescing | libs-gui NSView, libs-back | Minimize redrawn area; merge adjacent dirty rects; skip fully occluded views |
| Backing store management | libs-back, libs-quartzcore | Evaluate retained-mode backing stores; avoid full-window recomposition on partial update |
| Font rendering cache | libs-opal CoreText, libs-gui text system | Glyph cache sizing; font fallback chain caching; layout cache for repeated strings |
| Layer compositing optimization | libs-quartzcore CARenderer | Reduce per-layer overhead; batch property reads; minimize GL state changes |
| Animation frame scheduling | libs-quartzcore CADisplayLink | Adaptive frame rate; skip frames under load rather than stalling; vsync alignment |

### 6.6 Deliverables

- [ ] Performance baseline report with profiling data for each subsystem
- [ ] Optimization priority matrix (effort vs. impact for each item)
- [ ] Benchmark suite covering all optimized paths (before/after comparison)
- [ ] Patch set organized by optimization category

---

## Execution Guidelines

### Audit Methodology Per File

For each file under audit, follow this sequence:

1. **Read and understand** — Map the file's public API, internal state, and dependencies
2. **Thread safety analysis** — Identify shared mutable state; verify locking covers all access paths; check lock ordering against the hierarchy map
3. **Assertion audit** — Identify invariants that should hold but aren't asserted; check existing assertions for correctness
4. **Error path analysis** — Trace every error return / exception throw; verify cleanup (memory, locks, file handles)
5. **Performance profiling** — Identify hot paths (called frequently or with large data); measure allocation patterns; check for unnecessary copies
6. **Document findings** — Severity (Critical/High/Medium/Low), reproduction steps, proposed fix

### Severity Ratings

| Level | Definition | Example |
|-------|-----------|---------|
| **Critical** | Data corruption, security vulnerability, crash in production use | Race condition in retain/release causing use-after-free |
| **High** | Deadlock, assertion failure reachable via public API, significant performance regression | Lock ordering violation between NSRunLoop and NSThread |
| **Medium** | Thread safety issue requiring unusual usage pattern, moderate perf issue | Missing lock on NSNotificationCenter observer removal |
| **Low** | Missing assertion for internal invariant, minor optimization opportunity | Uncached hash value in immutable string |

### Testing Strategy

| Repo | Current Tests | Strategy |
|------|:------------:|----------|
| libobjc2 | 55 | Augment with thread-stress tests for dispatch table, selector table, ARC paths |
| libs-base | 490 | Add concurrency tests for NSRunLoop, NSOperation, NSNotificationCenter; fuzz serialization inputs |
| libs-corebase | 80 | Add assertion-validating tests; fuzz CFPropertyList, CFString |
| libs-opal | 27 | Add thread-confinement enforcement tests; stress-test CGPath construction |
| libs-quartzcore | 35 | Add animation lifecycle tests; concurrent CALayer mutation stress tests |
| libs-gui | 35 | Add view hierarchy stress tests; event dispatch concurrency tests |
| libs-back | **0** | **Bootstrap test suite** — start with headless backend tests, then platform-specific |

### Tooling

| Tool | Purpose |
|------|---------|
| ThreadSanitizer (TSan) | Detect data races at runtime |
| AddressSanitizer (ASan) | Detect use-after-free, buffer overflow, stack overflow |
| UndefinedBehaviorSanitizer (UBSan) | Detect signed overflow, null dereference, alignment issues |
| Valgrind / Dr. Memory | Heap profiling, leak detection (where sanitizers unavailable) |
| `perf` / Instruments / VTune | CPU profiling for hot path identification |
| AFL / libFuzzer | Fuzz serialization inputs (JSON, plist, nib, image codecs) |
| Clang Static Analyzer | Static analysis for null dereference, dead stores, logic errors |
| Custom lock-order checker | Build or adapt for GNUstep's lock hierarchy verification |

---

## Estimated Effort by Phase

| Phase | Scope | Relative Effort |
|-------|-------|:--------------:|
| Phase 1: libobjc2 | 150 files, runtime critical path | Medium |
| Phase 2: libs-base | 1,123 files, broadest surface | **Large** |
| Phase 3: libs-corebase | 153 files, assertion gap focus | Small-Medium |
| Phase 4: libs-opal + quartzcore | 270 files, thread safety gap focus | Medium |
| Phase 5: libs-gui + libs-back | 990 files, UI + backend | **Large** |
| Phase 6: Runtime optimization | Cross-cutting, profiling-driven | **Large** |

### Recommended Phase Ordering

```
Phase 1 (libobjc2) ──> Phase 2 (libs-base) ──> Phase 3 (libs-corebase)
                                                        │
Phase 6 can begin ◄────────────────────────────────────-┤
after Phase 2                                           │
                                                        v
                                Phase 4 (opal + quartzcore) ──> Phase 5 (gui + back)
```

Phase 6 (optimization deep dive) can begin after Phase 2 completes, running in parallel with Phases 4-5, since the runtime and foundation profiling data will be available by then.
