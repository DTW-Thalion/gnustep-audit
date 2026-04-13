# Spike B1 Addendum — Tail-append design failed, retrying with side-band storage

**Date:** 2026-04-13 (addendum to `docs/spikes/2026-04-13-per-class-cache-version.md`)
**Status:** First implementation attempt FAILED, retry with a different storage strategy.

## What the original spike got wrong

§2.1 and §3.2 of the B1 spike proposed adding `_Atomic(uint64_t) cache_generation` as a TAIL field on `struct objc_class`, asserting this was safe under libobjc2's "tail-append preserves existing offsets" ABI contract. The assumption was: because the runtime allocates / zero-initializes / copies class structures on load, it can safely treat the trailing bytes as runtime-owned storage past what the compiler emitted.

**This is wrong.** The first implementation pass:

1. Added the field at the end of `struct objc_class` (after `properties`).
2. Added `atomic_store_explicit(&class->cache_generation, 0, memory_order_relaxed);` in `objc_load_class` (`class_table.c`) per the spike's prescribed zero-init point.
3. Added `atomic_fetch_add_explicit(&class->cache_generation, 1, ...);` at the two `installMethodInDtable` bump sites in `dtable.c`.
4. Added an `OBJC_PUBLIC` getter and bumped SOVERSION 4.6 → 4.7.

The libobjc2 build was clean. The install produced `libobjc-4.7.dll`. But the runtime collapsed:
- libobjc2 native ctest: **40/104 pass**, 60 tests crashing with `STATUS_STACK_BUFFER_OVERRUN` (Windows CRT security-check abort, exit 0xc0000409).
- Instrumentation suite: crashed wholesale (exit 127) before running any assertion. 

**Root cause.** Clang's ObjC frontend emits each `@implementation` as a static class structure sized by clang's own ABI knowledge, not by reading `libobjc2/class.h`. The emitted class stops exactly at `properties` — nothing is reserved for `cache_generation`. When the runtime writes to `class->cache_generation`, it writes 8 bytes past the end of the emitted struct, clobbering adjacent static data: the next class object, a protocol list, an ivar list, or just section padding. `objc_load_class` in `class_table.c:412` never reallocates — it takes the compiler-emitted pointer as-is and operates on it in place.

The `legacy.c:344 objc_upgrade_class` path DOES reallocate (into a freshly `calloc`-ed buffer), but that path is only for the old gsv1 ABI. Modern v2 ABI classes (the common case by far) go straight to `objc_load_class` with the compiler-emitted pointer.

The tail-append claim the spike relied on (supported in the spike text by "abi_version and properties were added this way") is actually evidence of the opposite: those fields WORK because clang's codegen was updated in lockstep to emit them. No such codegen update exists or is practical for our `cache_generation` field within this audit's scope.

Rollback was performed: libobjc2 reverted to pristine + reinstalled at `libobjc-4.6.dll` (Apr 13 10:55), libs-base reverted + reinstalled (Apr 13 10:56), orphan `libobjc-4.7.dll` removed, **34/34 tests passing**, `bench_kvc_cache_storm` back to the pre-B1 baseline (7351 ns, storm present).

## The retry: side-band storage via `struct reference_list`

libobjc2 already has an extensibility mechanism that works around the compiler-emitted layout problem: `struct objc_class::extra_data`, a pointer to a heap-allocated `struct reference_list` used by the associated-objects API (`objc_setAssociatedObject`). Because `extra_data` itself is IN the compiler-emitted struct footprint (at offset 112 on LP64, followed only by `abi_version` at 120 and `properties` at 128 — both also in clang's emitted range), writing through the pointer is safe: clang sizes the class to include all three fields because it knows about all three.

The `struct reference_list` itself is defined privately in `libobjc2/associate.m` and is ONLY ever heap-allocated by libobjc2 runtime code — clang never emits it. **Adding a tail field to `struct reference_list` is therefore completely safe**, unlike adding one to `struct objc_class`.

### Retry design

1. **Add a field to `struct reference_list`** (inside `associate.m`):
   ```c
   struct reference_list
   {
       struct reference_list *next;
       mutex_t lock;
       void *gc_type;
       struct reference list[REFERENCE_LIST_SIZE];
       _Atomic(uint64_t) cache_generation;  // NEW — only meaningful on
                                             // the head of the chain
   };
   ```
   New allocations via `gc->malloc(sizeof(struct reference_list))` automatically include the field; existing call sites in `associate.m` are untouched.

2. **Add two helper functions in `associate.m`**, near the top of the file so they have access to the struct definition:
   ```c
   // Read the per-class cache generation. NULL-safe: returns 0 for
   // classes with no extra_data yet, matching the "never mutated"
   // interpretation the KVC cache wants.
   PRIVATE uint64_t _objc_class_cache_generation_load(Class cls);

   // Increment the per-class cache generation. Lazily creates
   // extra_data if absent. Called from installMethodInDtable bump
   // sites in dtable.c.
   PRIVATE void _objc_class_cache_generation_bump(Class cls);
   ```
   
   Lazy allocation mirrors the existing `referenceListForObject` pattern in `associate.m:285-308`:
   - Acquire `lock_for_pointer(cls)` (fine-grained spinlock used for class-level allocations)
   - If `cls->extra_data` is still NULL, `gc->malloc` a zeroed `reference_list` and publish it
   - Otherwise free the losing allocation
   - Release the spinlock
   - Atomic fetch-add on `extra_data->cache_generation`

3. **Public C API in `objc/slot.h`**:
   ```c
   OBJC_PUBLIC uint64_t objc_class_cache_generation_np(Class cls);
   ```
   Implementation is a single thin wrapper in `associate.m` or `dtable.c` calling `_objc_class_cache_generation_load`. The `_np` suffix follows libobjc2 convention for non-portable extensions (e.g., `objc_registerSmallObjectClass_np`).

4. **Wire up the bump sites in `dtable.c`**: at each of the two existing `objc_method_cache_version++` sites (inside `installMethodInDtable` with `oldMethod != NULL`, and inside `objc_update_dtable_for_new_superclass`), add a call to `_objc_class_cache_generation_bump(class)`. The global counter stays untouched — this is the dual-counter phase A rollout, so the global counter still moves for any consumer that reads it, and per-class counters move alongside for consumers that opt in.

5. **Bump libobjc2 `libobjc_VERSION` from 4.6 → 4.7** in `CMakeLists.txt:36`. Adding one new exported symbol (the getter) is a minor version bump; no struct layout changes mean zero binary-compatibility risk for existing consumers.

6. **Consumer side: libs-base `NSKeyValueCoding+Caching.m`**:
   - Pass the `Class cls` into `_getBoxedBlockForMethod` (currently takes `Method method, SEL sel, uint64_t version` — replace `version` with `cls` and compute the stamp inside).
   - Similarly thread `Class cls` into `_getBoxedBlockForIVar`.
   - Stamp slots as `slot.version = objc_class_cache_generation_np(cls)` instead of the global counter value that `objc_get_slot2` writes via its out-param.
   - Change the hot-path check at `NSKeyValueCoding+Caching.m:623` from `if (objc_method_cache_version != cachedSlot->version)` to `if (objc_class_cache_generation_np(cachedSlot->cls) != cachedSlot->version)`.

### Cost vs benefit vs the original tail-field design

| | Tail field (failed) | Side-band via extra_data (retry) |
|---|---|---|
| Read cost | 1 atomic load (~2 ns) | 1 pointer load + NULL check + 1 atomic load (~5-10 ns) |
| Bump cost | 1 atomic RMW | 1 lazy alloc on first bump, then 1 atomic RMW |
| ABI risk | HIGH — corrupts emitted class objects | ZERO — `extra_data` is already within the emitted footprint |
| SOVERSION bump | 4.6 → 4.7 (minor) | 4.6 → 4.7 (minor) |
| Storm reduction | 744 ns → ~2 ns if it worked | 744 ns → ~50 ns realistic estimate |

The side-band design is slower per read (one extra pointer chase) but still delivers a ~15× improvement on the uncached KVC path, far above the noise floor. The lazy allocation on first bump is amortized across the first bump per class, which is a one-time cost per class during program lifetime.

## Gate for the retry

Same as the original B1 gate: `instrumentation/benchmarks/bench_kvc_cache_storm.m` must show a meaningful reduction in `kvc_cache_storm` ns/op compared to the current baseline of ~7350 ns. Target: **<2000 ns** (a ~3.5× improvement) to justify the complexity. A result closer to `kvc_cache_hot` (~313 ns) would be ideal, but the pointer-chase overhead in the read path probably prevents matching it exactly.

If the retry passes the gate, commit to both repos. If it fails or breaks tests again, **abandon B1** and close as infeasible under the current libobjc2/clang ecosystem.

## Status

Design recorded, retry implemented and measured, then reverted after reviewer feedback — see below.

---

## Reviewer feedback (2026-04-13, late)

After implementing and committing the side-band retry (libobjc2 `0cc8962`, libs-base `c12ac2391`, storm reduced 23x on the microbenchmark), an expert reviewer with deep libobjc2 knowledge rejected the premise. Their response to the audit finding that motivated B1 (originally tracked as PF-4):

> *"PF-4 was an intentional design choice. Method replacements are infrequent. The proposed change would make things worse."*

Their point in detail: the global `objc_method_cache_version` counter works the way it does because the runtime assumes method replacements are RARE events (hours or days apart in a real application, not microseconds). Category loading happens at `dlopen`, once per process. `class_replaceMethod` on an already-registered class bypasses the dtable path entirely and does NOT bump the counter (as we verified earlier today in the bench_kvc_cache_storm diagnostic). KVO install bumps the counter by ~309 once per swizzled subclass, which happens at most once per observed class per process lifetime. In aggregate, the counter moves maybe a few dozen times during program startup and then stays effectively static for the rest of the run.

Our `bench_kvc_cache_storm` measured 23x reduction by directly incrementing `objc_method_cache_version` via `atomic_fetch_add_explicit` in a 10,000-iteration tight loop — a scenario that does not occur in any real workload. The 320 ns post-B1 storm number measures "what KVC cost would be IF the counter were being bumped 10,000 times per iteration" — but in a real application the counter is static after startup, so ALL KVC lookups hit the fast path and the refresh cost is never paid.

**The B1 optimization is real in the microbenchmark but practically irrelevant in production.** The reviewer correctly identified this: adding per-class counters introduces a pointer chase on every KVC check (read `cls->extra_data`, null check, read the atomic field) in exchange for eliminating a refresh cost that virtually never happens in production workloads. Net effect on real applications: **slightly slower**, because we added overhead to the hot path to fix a cold path that wasn't hot to begin with.

### Decision: REVERT B1 Phase A

Under the audit's performance rule — "purely performance-motivated change that does not improve real-workload performance should be reverted unless there is a compelling reason to retain" — B1 fails the rule. The compelling-reason test would require evidence of a real workload where method mutations happen frequently enough for the storm to bite, and we have no such evidence. The reviewer's domain knowledge is the dispositive evidence pointing the other direction.

**Reverts applied:**
- `libobjc2` commit `a361c1a` reverts `0cc8962` (removes the cache_generation field from `struct reference_list`, removes helpers and OBJC_PUBLIC wrapper, removes bump calls in dtable.c, removes declaration in objc/slot.h).
- `libs-base` commit `2c5eb64fa` reverts `c12ac2391` (restores KVC cache to using the global `objc_method_cache_version` comparison).
- Both reverts rebuilt, installed, and 34/34 regression tests confirmed passing.
- `bench_kvc_cache_storm` confirmed back to pre-B1 baseline (7279 ns, matching the ~7350 ns pre-B1 number within noise).

### Retained from the failed retry

The `instrumentation/benchmarks/bench_kvc_cache_storm.m` benchmark stays committed as **instrumentation infrastructure**. It is useful for anyone who later finds a real workload where the counter moves frequently enough to matter — in that case, re-measure with a representative benchmark (not a tight loop on `atomic_fetch_add`) and re-open the question with real-workload evidence. The `baseline_pre_b1.jsonl` historical artifact stays as a snapshot of the pre-B1 canonical state.

### Lessons

1. **Microbenchmarks can mislead.** A 23x reduction on a synthetic benchmark is meaningless if the synthetic scenario does not map to any production workload. Our `kvc_counter_bump` microbenchmark paid 4 ns per bump and our storm benchmark paid 730 ns per slot refresh — those numbers are real, but the bump rate in production is a few dozen per program lifetime, not 10,000 per millisecond.

2. **Defer to domain expertise when it contradicts microbenchmark optimism.** The reviewer knew the design history and the realistic mutation frequency. We knew only what the synthetic benchmark measured. Their judgment was the correct tiebreaker.

3. **The audit's original PF-4 framing was itself wrong.** The audit found this as a finding because the code LOOKED expensive (process-wide invalidation on method replacement!), and the microbenchmark confirmed it was expensive IF exercised. But the runtime's design explicitly assumed the path would not be exercised at high frequency, and that assumption is correct in practice. The finding should have been closed during the original audit as "theoretically a hot path, practically static."

### Status

B1 Phase A: **REVERTED, closed.** No further B1 work planned. The bench_kvc_cache_storm benchmark + historical baselines remain as instrumentation for any future re-evaluation.
