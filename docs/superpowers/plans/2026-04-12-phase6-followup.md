# Phase 6 Follow-up: Remaining Optimizations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the two remaining concrete optimization items from the original Phase 6 perf plan (NSRunLoop timer scan cached limit date; GSHashTable tombstone accumulation GC), then produce design spikes for the seven Sprint 4/5 architectural items the original plan documented as future work.

**Architecture:** Hybrid plan. Part A contains concrete TDD-style tasks for items where the code path and data structures are settled. Part B contains research spikes — each spike's deliverable is a design document (committed to `docs/`) that becomes the spec for a future implementation plan. This split exists because the Sprint 4/5 items are ABI changes or cross-cutting refactors whose exact code shape cannot be responsibly specified without first reading the target files and validating assumptions against current code. Skipping the spike step and writing fabricated step-by-step code would produce a plan that looks complete but doesn't match reality.

**Tech Stack:** C (libobjc2, libs-corebase), Objective-C / GNUstep-make (libs-base, libs-opal, libs-quartzcore, libs-gui, libs-back), clang + gnustep-2.0 runtime, MSYS2 ucrt64 toolchain, existing instrumentation suite in `gnustep-audit/instrumentation/`.

**Reference:** `docs/phase6-optimization-deep-dive.md` §6 Sprint 4 and Sprint 5.

**Scope note:** This plan spans five repos (libobjc2, libs-base, libs-corebase, libs-opal, libs-quartzcore). Each Part A task is a self-contained commit on one repo. Each Part B spike produces one design doc committed to `gnustep-audit/docs/`. Implementation of spike findings happens in follow-up plans, one per approved design.

---

## Pre-Task: Correct the stale status line in phase6 doc

**Files:**
- Modify: `docs/phase6-optimization-deep-dive.md:4`

**Context:** The header line currently reads `**Status:** 12 of 15 optimizations applied (3 deferred as optional/low-impact)`. Cross-reference against committed perf work shows 14 of 15 were shipped pre-follow-up, one was explicitly deferred (Task 9 NSRunLoop timer optimization), and PF-7 had a 2-site miss in arc.mm which has now been closed by commit `834c978` on DTW-Thalion/libobjc2. Updating the line to reflect the real state and point at this follow-up plan.

- [ ] **Step P.1: Rewrite the status line**

Replace `docs/phase6-optimization-deep-dive.md:4` with:

```markdown
**Status:** Sprint 1-3 complete (15/15 tasks — Task 9 NSRunLoop timer optimization was deferred at audit close and is now tracked by the follow-up plan at `docs/superpowers/plans/2026-04-12-phase6-followup.md`, which also covers the Sprint 4/5 architectural items listed below as design spikes). PF-7 (__sync_fetch_and_add -> __atomic_load_n) fully closed by libobjc2 commit 834c978.
```

- [ ] **Step P.2: Commit**

```bash
cd /c/Users/toddw/source/repos/gnustep-audit
git add docs/phase6-optimization-deep-dive.md
git commit -m "docs(phase6): correct stale status line, point to follow-up plan"
```

---

## Part A: Concrete Tasks

---

### Task A1: NSRunLoop `_limitDateForContext:` cached limit date

**Files:**
- Modify: `libs-base/Source/GSRunLoopCtxt.h` (add one `NSDate *_cachedLimitDate` ivar plus init/dealloc handling)
- Modify: `libs-base/Source/unix/GSRunLoopCtxt.m` (POSIX impl of `GSRunLoopCtxt`; release the cache in `-dealloc`)
- Modify: `libs-base/Source/win32/GSRunLoopCtxt.m` (Windows impl; same change)
- Modify: `libs-base/Source/NSRunLoop.m` lines 1006-1128 (use cache in `_limitDateForContext:`, invalidate on add/remove)
- Modify: `libs-base/Source/NSRunLoop.m` at every site that adds/removes a timer from `context->timers` (search for `context->timers`, `addTimer:`, `removeTimer:`, `GSIArrayAddItemNoRetain(.*timers`, `GSIArrayRemoveItemAtIndex.*timers`)
- Test: `instrumentation/tests/libs-base/test_runloop_timer_cache.m` (new)
- Benchmark: `instrumentation/benchmarks/bench_runloop_timers.m` already exercises this path; re-run before/after.

**Context (from perf plan lines 715-736):** `_limitDateForContext:` iterates every timer on every runloop iteration — once to fire due timers, once more to compute the earliest future fire date. For typical apps with `N < 20` timers the cost is small, but apps using many periodic NSTimers (tracker panels, animation engines, polling UIs) see N >> 20 and the O(N) scan dominates their runloop cost. Plan deferred this originally because the fix touches the private `GSRunLoopCtxt.h` header. That header IS private to libs-base, so the change is safe within the repo.

**Design:** Add `NSDate *_cachedLimitDate` to `GSRunLoopCtxt`. After the second scan (lines 1078-1097) computes `earliest`, store it in `_cachedLimitDate` (retained). On subsequent calls, if the cache is non-nil AND `_cachedLimitDate > now` AND no timer in the array is past-due, return the cached value without the second scan. Any mutation of `context->timers` (add, remove, timer invalidation) must nil out the cache.

The "no timer past-due" check is still O(N) in the worst case, but the common case is "none past-due" and we can short-circuit on the first past-due timer. The real savings come from eliminating the earliest-date scan in the common case where no timers need firing.

Cache invariant: `_cachedLimitDate == nil` means "scan required". After a full scan sets it, it remains valid until any mutation.

- [ ] **Step A1.1: Add the failing test**

Create `instrumentation/tests/libs-base/test_runloop_timer_cache.m`:

```objc
// test_runloop_timer_cache.m — verify NSRunLoop limit-date cache correctness
// This test validates behavior, not performance. The benchmark
// (bench_runloop_timers) measures the speedup.
#import <Foundation/Foundation.h>
#import "../common/test_utils.h"

@interface Counter : NSObject {
@public
    int n;
}
- (void) tick: (NSTimer *)t;
@end

@implementation Counter
- (void) tick: (NSTimer *)t { n++; }
@end

int main(void)
{
    @autoreleasepool {
        NSRunLoop *rl = [NSRunLoop currentRunLoop];
        Counter *c = [[Counter alloc] init];

        // Install 50 timers with staggered future fire dates.
        // All should fire exactly once within the test window.
        for (int i = 0; i < 50; i++) {
            NSTimeInterval when = 0.01 + (i * 0.001);
            [NSTimer scheduledTimerWithTimeInterval: when
                                             target: c
                                           selector: @selector(tick:)
                                           userInfo: nil
                                            repeats: NO];
        }

        // Run until all 50 have fired (with a safety cap).
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow: 2.0];
        while (c->n < 50 && [deadline timeIntervalSinceNow] > 0) {
            [rl runMode: NSDefaultRunLoopMode
             beforeDate: [NSDate dateWithTimeIntervalSinceNow: 0.01]];
        }

        TEST_ASSERT_EQ(c->n, 50, "all 50 timers fired exactly once");

        // Add a new timer AFTER the first batch drained — verify cache
        // invalidation on add: the new timer must fire.
        c->n = 0;
        [NSTimer scheduledTimerWithTimeInterval: 0.01
                                         target: c
                                       selector: @selector(tick:)
                                       userInfo: nil
                                        repeats: NO];
        deadline = [NSDate dateWithTimeIntervalSinceNow: 0.5];
        while (c->n < 1 && [deadline timeIntervalSinceNow] > 0) {
            [rl runMode: NSDefaultRunLoopMode
             beforeDate: [NSDate dateWithTimeIntervalSinceNow: 0.01]];
        }
        TEST_ASSERT_EQ(c->n, 1, "timer added after drain still fires (cache invalidated on add)");

        [c release];
    }
    TEST_RESULT_PASS();
    return 0;
}
```

Update `instrumentation/tests/libs-base/GNUmakefile` to add `test_runloop_timer_cache` to the `TESTS` list and `test_runloop_timer_cache_OBJC_FILES = test_runloop_timer_cache.m`.

- [ ] **Step A1.2: Run the test against unpatched libs-base and confirm it passes**

This is a behavior test and the unpatched code is already correct — the test should pass on the baseline. Its purpose is to guard against the cache change introducing a regression. If it already fails, the test is wrong and should be fixed before proceeding.

```bash
cd /c/Users/toddw/source/repos/gnustep-audit/instrumentation/tests/libs-base
make all GNUSTEP_MAKEFILES=/c/msys64/ucrt64/share/GNUstep/Makefiles CC=clang
make run-tests GNUSTEP_MAKEFILES=/c/msys64/ucrt64/share/GNUstep/Makefiles CC=clang
```

Expected: `test_runloop_timer_cache PASS`.

- [ ] **Step A1.3: Add the cached limit date ivar to GSRunLoopCtxt**

Edit `libs-base/Source/GSRunLoopCtxt.h` — after the `BOOL completed;` line (currently line 75), add:

```c
  NSDate        *_cachedLimitDate; // Cached result of _limitDateForContext:,
                                   // nil means a rescan is required. Retained.
```

- [ ] **Step A1.4: Release the cache on dealloc and invalidate on every timer mutation**

Edit **both** platform impls of `GSRunLoopCtxt`:
- `libs-base/Source/unix/GSRunLoopCtxt.m`
- `libs-base/Source/win32/GSRunLoopCtxt.m`

In each `-dealloc`, add before the `[super dealloc]` line:

```objc
  RELEASE(_cachedLimitDate);
  _cachedLimitDate = nil;
```

In `libs-base/Source/NSRunLoop.m`, find every site that mutates `context->timers`. With ripgrep:

```bash
cd /c/Users/toddw/source/repos/gnustep-audit/libs-base
grep -n 'context->timers\|->timers' Source/NSRunLoop.m
```

At each mutation site (add, remove, set), immediately after the mutation, insert:

```objc
  DESTROY(context->_cachedLimitDate); // invalidate cache on any timer mutation
```

`DESTROY` is the existing GNUstep macro that releases and nils. Verify it's available in this translation unit (it is — used elsewhere in NSRunLoop.m).

- [ ] **Step A1.5: Use the cache in `_limitDateForContext:`**

Edit `libs-base/Source/NSRunLoop.m` at `_limitDateForContext:` (line 1006). Replace the body starting at line 1074 ("Now, find the earliest remaining timer date...") — the second scan — with a cache-aware version. The final shape:

```objc
  /* Cache-aware path: if we have a cached limit date that is still in
   * the future AND the past-due check above did not fire anything
   * (i.e., the cache is still consistent with the current timer set),
   * return it without rescanning. Any mutation to context->timers
   * between calls nils _cachedLimitDate, forcing a rescan. */
  if (context->_cachedLimitDate != nil
      && [context->_cachedLimitDate timeIntervalSinceReferenceDate] > now)
    {
      [arp drain];
      return AUTORELEASE(RETAIN(context->_cachedLimitDate));
    }

  /* Cache miss — full scan to find the earliest remaining timer date
   * while removing invalidated timers. Iterate from the end of the
   * array to minimise shifting. */
  earliest = nil;
  i = GSIArrayCount(timers);
  while (i-- > 0)
    {
      t = GSIArrayItemAtIndex(timers, i).obj;
      if (timerInvalidated(t) == YES)
        {
          GSIArrayRemoveItemAtIndex(timers, i);
          DESTROY(context->_cachedLimitDate); // invalidate: set changed
        }
      else
        {
          d = timerDate(t);
          ti = [d timeIntervalSinceReferenceDate];
          if (earliest == nil || ti < ei)
            {
              earliest = d;
              ei = ti;
            }
        }
    }
  [arp drain];

  /* Populate the cache with the fresh result. */
  if (earliest != nil)
    {
      ASSIGN(context->_cachedLimitDate, earliest);
      when = AUTORELEASE(RETAIN(earliest));
    }
  else
    {
      /* No timers — existing watcher fallback path below. Leave
       * _cachedLimitDate nil so the next call rescans. */
      DESTROY(context->_cachedLimitDate);
      GSIArray      watchers = context->watchers;
      unsigned      wi = GSIArrayCount(watchers);
      while (wi-- > 0)
        {
          GSRunLoopWatcher *w = GSIArrayItemAtIndex(watchers, wi).obj;
          if (w->_invalidated == YES)
            {
              GSIArrayRemoveItemAtIndex(watchers, wi);
            }
        }
      if (GSIArrayCount(context->watchers) > 0)
        {
          when = theFuture;
        }
    }

  return when;
```

Note: `ASSIGN` is GNUstep's release-old + retain-new macro; `DESTROY` is release + nil. Both are already used in NSRunLoop.m. Do NOT introduce manual RELEASE/RETAIN on the cache field.

Also note: the important invariant is that `_cachedLimitDate` never points to an invalidated timer's date. Because the scan removes invalidated timers AND the cache only stores the dereferenced `earliest` (an NSDate, retained independently), the NSDate itself will outlive its parent NSTimer via the retain. That's safe — the cache returns a valid date even if its owning timer was subsequently invalidated; the next call will detect the mutation via the cache-invalidation hooks added in Step A1.4.

- [ ] **Step A1.6: Build libs-base and run the test**

```bash
cd /c/Users/toddw/source/repos/gnustep-audit/libs-base
make GNUSTEP_MAKEFILES=/c/msys64/ucrt64/share/GNUstep/Makefiles CC=clang
sudo -n make install GNUSTEP_MAKEFILES=/c/msys64/ucrt64/share/GNUstep/Makefiles CC=clang || \
    make install GNUSTEP_MAKEFILES=/c/msys64/ucrt64/share/GNUstep/Makefiles CC=clang
cd /c/Users/toddw/source/repos/gnustep-audit/instrumentation/tests/libs-base
make clean && make all GNUSTEP_MAKEFILES=/c/msys64/ucrt64/share/GNUstep/Makefiles CC=clang
make run-tests GNUSTEP_MAKEFILES=/c/msys64/ucrt64/share/GNUstep/Makefiles CC=clang
```

Expected: all 13 libs-base tests (12 existing + 1 new) PASS.

- [ ] **Step A1.7: Measure with the existing runloop benchmark**

```bash
cd /c/Users/toddw/source/repos/gnustep-audit/instrumentation/benchmarks
make clean && make all GNUSTEP_MAKEFILES=/c/msys64/ucrt64/share/GNUstep/Makefiles CC=clang
./obj/bench_runloop_timers.exe --json
```

Compare against the current post-fix baseline at `instrumentation/benchmarks/results/baseline.jsonl`. The `runloop_100_timers`, `runloop_1000_timers` lines should improve (the plan's 60-70% expected win is for N=1000+; smaller N will see proportionally less). A null result for N=10 is acceptable — the optimization targets the many-timer case.

- [ ] **Step A1.8: Commit**

Two commits: one in libs-base (the fix), one in gnustep-audit (the test + results). Use `git -c user.name="Todd White" -c user.email="todd.white@thalion.global"` for the libs-base commit to match existing audit identity.

```bash
cd /c/Users/toddw/source/repos/gnustep-audit/libs-base
git add Source/GSRunLoopCtxt.h Source/NSRunLoop.m Source/GSRunLoop.m
git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "perf: cache _limitDateForContext result to eliminate O(N) timer rescan

Add _cachedLimitDate to GSRunLoopCtxt; return cached value when still
in the future, invalidate on any timer mutation (add/remove/invalidate).
Closes Task 9 from docs/superpowers/plans/2026-04-12-perf-optimization.md,
which was deferred at audit close and carried forward by
docs/superpowers/plans/2026-04-12-phase6-followup.md.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
git push myfork master   # or origin — check git remote -v in that repo

cd /c/Users/toddw/source/repos/gnustep-audit
git add instrumentation/tests/libs-base/test_runloop_timer_cache.m \
        instrumentation/tests/libs-base/GNUmakefile
git commit -m "test: add NSRunLoop timer limit-date cache correctness test"
git push origin main
```

---

### Task A2: GSHashTable tombstone accumulation + rehash

**Files:**
- Modify: `libs-corebase/Source/GSHashTable.h:72-82` (add `_tombstoneCount` field to `struct GSHashTable`)
- Modify: `libs-corebase/Source/GSHashTable.c` (all sites — see Step A2.1)
- Test: `instrumentation/tests/libs-corebase/test_hash_tombstone.c` (new)
- Benchmark: `instrumentation/benchmarks/bench_dict_lookup.m` (exercises this path indirectly via CFDictionary)

**Context (from original perf plan, `2026-04-12-fix-libs-corebase.md:909`):** `GSHashTable` uses open addressing with linear probing. Removing a key does not free the bucket — it marks it as a "deleted" tombstone so probe chains stay intact. Over time, a table with heavy churn accumulates tombstones and probe chains grow arbitrarily long, degrading O(1) lookups to O(N). The fix is to track tombstone count and trigger a rehash when tombstones exceed a threshold (typical rule: `tombstones > capacity/4`).

**Prerequisite for implementer:** read the full `libs-corebase/Source/GSHashTable.c` before starting. The plan below describes intent and structure; exact line numbers depend on how the existing remove path marks tombstones (sentinel value in `bucket->key`, vs `bucket->count == 0`, vs separate flag). That determination is step A2.1.

- [ ] **Step A2.1: Characterize the current tombstone scheme**

```bash
cd /c/Users/toddw/source/repos/gnustep-audit/libs-corebase/Source
grep -n 'GSHashTableRemove\|bucket->key\|bucket->count\|probe\|tombstone\|deleted' GSHashTable.c
```

Read the full `GSHashTableRemoveValue`, the probe/lookup loop, and the insert path. Identify:
- How is an empty bucket distinguished from a tombstone during probe? (Most likely: empty has `count == 0 && key == NULL`; tombstone has `count == 0 && key == <sentinel>`, OR there's no tombstone at all and remove currently breaks the probe chain — which would be a separate pre-existing bug.)
- Where is the probe loop?
- Is there existing rehash logic on insert (grow when `_count > _capacity * load_factor`)?

Write findings into a short comment block at the top of GSHashTable.c (5-10 lines) so the diff is self-explaining. This is not a commit — it's scratch for the implementer's orientation.

- [ ] **Step A2.2: Add the failing test**

Create `instrumentation/tests/libs-corebase/test_hash_tombstone.c`:

```c
/* test_hash_tombstone.c — insert N, remove half, insert again. With
 * tombstone GC, the second insert batch must not cause probe chains
 * to exceed sqrt(capacity). Without GC, repeat this pattern many times
 * and probe length grows unbounded.
 *
 * This test is skipped if libgnustep-corebase headers are not
 * installed (matching the skip policy used by the other
 * libs-corebase tests).
 */
#include "../../common/test_utils.h"

#ifndef HAVE_COREFOUNDATION
int main(void) {
    TEST_SKIP("CoreFoundation headers/libgnustep-corebase not installed");
    return 0;
}
#else

#include <CoreFoundation/CFDictionary.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(
        NULL, 0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    TEST_ASSERT(d != NULL, "dictionary created");

    const int N = 10000;
    CFStringRef *keys = calloc(N, sizeof(*keys));
    for (int i = 0; i < N; i++) {
        char buf[32];
        snprintf(buf, sizeof(buf), "k%d", i);
        keys[i] = CFStringCreateWithCString(NULL, buf, kCFStringEncodingUTF8);
    }

    /* Churn: 20 rounds of insert-N / remove-all. Without tombstone GC,
     * internal tombstones accumulate and lookup degrades. */
    for (int round = 0; round < 20; round++) {
        for (int i = 0; i < N; i++)
            CFDictionarySetValue(d, keys[i], keys[i]);
        TEST_ASSERT_EQ((int)CFDictionaryGetCount(d), N,
                       "count matches after insert batch");
        for (int i = 0; i < N; i++)
            CFDictionaryRemoveValue(d, keys[i]);
        TEST_ASSERT_EQ((int)CFDictionaryGetCount(d), 0,
                       "count zero after remove batch");
    }

    /* After churn: inserting again and doing a lookup should still be
     * cheap. We can't directly observe probe length from public API,
     * but a simple behavioral assertion catches the worst cases. */
    for (int i = 0; i < N; i++)
        CFDictionarySetValue(d, keys[i], keys[i]);
    for (int i = 0; i < N; i++) {
        const void *v = CFDictionaryGetValue(d, keys[i]);
        TEST_ASSERT(v == keys[i], "lookup after churn returns correct value");
    }

    for (int i = 0; i < N; i++) CFRelease(keys[i]);
    free(keys);
    CFRelease(d);

    TEST_RESULT_PASS();
    return 0;
}
#endif
```

Add to `instrumentation/tests/libs-corebase/GNUmakefile` in the TESTS list and with the corresponding `_C_FILES = test_hash_tombstone.c` line.

- [ ] **Step A2.3: Add `_tombstoneCount` to the struct**

Edit `libs-corebase/Source/GSHashTable.h:72-82`. Insert one new field:

```c
struct GSHashTable
{
  CFRuntimeBase _parent;
  CFAllocatorRef _allocator;
  CFIndex _capacity;
  CFIndex _count;
  CFIndex _tombstoneCount;       /* Number of deleted-but-unfreed buckets.
                                    Triggers rehash when > _capacity / 4. */
  CFIndex _total;                /* Used for CFBagGetCount() */
  GSHashTableKeyCallBacks _keyCallBacks;
  GSHashTableValueCallBacks _valueCallBacks;
  struct GSHashTableBucket *_buckets;
};
```

- [ ] **Step A2.4: Wire the counter into the remove, add, and create paths**

In `GSHashTable.c`:

1. `GSHashTableCreate*` — initialize `table->_tombstoneCount = 0`.
2. `GSHashTableRemoveValue` — after the existing tombstone marking, `table->_tombstoneCount++;`.
3. `GSHashTableAddValue` / `GSHashTableSetValue` — if the insert reuses a tombstone bucket (probe found a tombstone then an empty or same-key slot), decrement `_tombstoneCount`.
4. `GSHashTableRemoveAll` — set `_tombstoneCount = 0`.
5. The internal rehash / grow routine (call it `GSHashTableRehash` — name it after whatever already exists) — reset `_tombstoneCount = 0` on the rehashed table.

After step A2.1 the implementer knows the exact lines. Do not write speculative line numbers here.

- [ ] **Step A2.5: Trigger rehash on tombstone pressure**

At the top of `GSHashTableAddValue` (and any other write entry point identified in A2.1), before the probe loop, add:

```c
  /* Tombstone GC: if deleted-bucket pressure has exceeded capacity/4,
   * rehash now. This keeps probe chains bounded under churn. */
  if (table->_tombstoneCount > table->_capacity / 4)
    {
      GSHashTableRehash (table, table->_capacity);
    }
```

Use whatever symbol the existing grow logic uses. If no same-size rehash routine exists, the simplest addition is:

```c
static void
GSHashTableRehashInPlace (GSHashTableRef table)
{
  /* Allocate a new bucket array of the same capacity, walk the old
   * one, re-insert every non-tombstone entry into the new one, swap,
   * free the old. Reset _tombstoneCount to 0. */
  ...
}
```

Write that helper if needed. Keep it private (file-scope `static`).

- [ ] **Step A2.6: Build, install, run the test**

```bash
cd /c/Users/toddw/source/repos/gnustep-audit/libs-corebase
# libs-corebase uses CMake in most configurations — check CMakeLists.txt
# and use the same build invocation used by the prior audit commits
# (see git log --oneline | grep -i perf for the exact pattern).
# If it's gnustep-make:
make GNUSTEP_MAKEFILES=/c/msys64/ucrt64/share/GNUstep/Makefiles CC=clang
make install GNUSTEP_MAKEFILES=/c/msys64/ucrt64/share/GNUstep/Makefiles CC=clang
```

Note: libs-corebase tests currently report SKIPPED on the main dev box because the CoreFoundation headers aren't installed. The new test will also skip in that environment. Getting the test to actually run requires installing libgnustep-corebase — that's a prerequisite, not part of this task. Mark the commit as "test runs where headers installed" rather than chasing the install path.

- [ ] **Step A2.7: Commit**

```bash
cd /c/Users/toddw/source/repos/gnustep-audit/libs-corebase
git add Source/GSHashTable.h Source/GSHashTable.c
git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "perf: rehash on tombstone pressure to keep open-addressing probe chains bounded

Track _tombstoneCount alongside _count; when deleted-bucket pressure
exceeds _capacity/4, rehash in place. Closes the follow-up PR noted
in docs/superpowers/plans/2026-04-12-fix-libs-corebase.md:909.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
git push origin master  # verify remote name first

cd /c/Users/toddw/source/repos/gnustep-audit
git add instrumentation/tests/libs-corebase/test_hash_tombstone.c \
        instrumentation/tests/libs-corebase/GNUmakefile
git commit -m "test: add GSHashTable tombstone GC churn test"
git push origin main
```

---

## Part B: Research Spikes

Each spike produces ONE design document committed to `gnustep-audit/docs/spikes/YYYY-MM-DD-<name>.md`. The design doc is the deliverable. Implementation is a follow-up plan generated from the approved design.

**Spike template** — every spike doc must answer:

1. **Current state**: exact files, functions, line numbers, and data structures involved today.
2. **Proposed change**: the design, in enough detail to estimate scope.
3. **ABI impact**: what breaks, what a consumer rebuild catches, what requires a .so version bump.
4. **Performance estimate**: expected impact with the unit (ns, µs, %, x-factor) and which existing benchmark would observe it. Add a new benchmark if none exists.
5. **Risk**: likelihood of regression, surfaces affected, worst-case rollback path.
6. **Test strategy**: what correctness test catches the change, what benchmark measures it.
7. **Decision**: GO / NO-GO / NEEDS-DISCUSSION, with a one-sentence rationale.

Review each spike before promoting to an implementation plan. Spike doc + review comments → approved design → new plan file.

---

### Spike B1: Per-class method cache generation counters (libobjc2)

**Target:** `libobjc2/dtable.c` line 47 (`objc_method_cache_version`), `objc_msgSend.*.S` (all arches), callsite caches in consumers that read `objc_method_cache_version`.

**Problem:** A single global `_Atomic(uint64_t) objc_method_cache_version` is incremented on any class method list change. Every cached IMP in every call site is invalidated system-wide, even though only one class changed. KVO, dynamic method resolution, and category loading each trigger a cache storm.

**Research questions:**
1. How many call sites currently read `objc_method_cache_version`? (`grep -rn objc_method_cache_version libobjc2/` plus any GNUstep-base and libs-gui usages.)
2. Does the asm fast path in `objc_msgSend.x86-64.S` load this version as part of the hot loop, or only on slow-path refill? (Read the .S file; determine cache-line layout.)
3. What's the minimum data needed per class for a generation counter? One `uint64_t` added to `struct objc_class`? Or a side table keyed on class pointer?
4. Is `struct objc_class` publicly exposed such that adding a field is an ABI break, or is it already opaque to non-runtime callers?
5. What's the smallest set of consumers that need to rebuild? Just libobjc2, or every libobjc2 client?

**Deliverable:** `docs/spikes/2026-04-13-per-class-cache-version.md` following the spike template.

**Estimated effort:** 1-2 days of reading, 0.5 day of writing the doc.

---

### Spike B2: Tagged-pointer / small-string NSString (libs-base)

**Target:** `libs-base/Source/NSString.m`, `libs-base/Source/Additions/GSObjCRuntime.m`, `libs-base/Source/GSPrivate.h` (small-obj class table if it exists).

**Problem:** Every NSString allocates at least one heap object (typically two — the NSString instance plus the character buffer). For short ASCII strings (<= 7 or 15 bytes on 64-bit), the entire payload fits in the pointer bits using the runtime's small-object tagging mechanism. This is how Apple's CoreFoundation handles short strings and gives a ~2x perf win on string-heavy workloads (property lookups, selector names, KVC keys).

**Research questions:**
1. Does libobjc2's small-object infrastructure already expose a class slot for strings, or only for numbers/dates? (Read `libobjc2/smallint.c` if it exists, plus `SmallObject` in class_table.c.)
2. What's the tag layout on x86-64, aarch64, and 32-bit targets? How many payload bits per target?
3. What existing NSString methods can be implemented directly on the tagged pointer (length, characterAtIndex:, getCString:, UTF8String, hash, isEqual:) vs which require realizing to a heap object (mutableCopy, substringFromIndex:, etc.)?
4. How does this interact with +stringWithUTF8String: and other factories — can they return a tagged pointer for short input?
5. Correctness risk: are there libs-base code paths that cast NSString to a C pointer and dereference it? Any site that assumes `object_getClass(str) != NULL` or reads an isa word?
6. Performance ceiling: estimated % of NSString allocations that fall in the <=7-byte ASCII bucket on a typical GNUstep workload. Measure with an instrumented libs-base run.

**Deliverable:** `docs/spikes/2026-04-13-tagged-pointer-nsstring.md`.

**Estimated effort:** 2 days reading (smallint.c, NSString.m, objc_msgSend.S for small-obj dispatch), 1 day writing.

---

### Spike B3: `dtable` field cache-line move adjacent to `isa` (libobjc2)

**Target:** `libobjc2/class.h` (struct objc_class layout), `libobjc2/objc_msgSend.*.S` (hot path reads dtable via offset from isa).

**Problem:** The `dtable` pointer is not adjacent to `isa` in `struct objc_class`, so `objc_msgSend` pays a cache-line miss on cold classes (load isa, load dtable — second load may fall on a different line). Moving dtable adjacent to isa eliminates that miss.

**Research questions:**
1. Current layout of `struct objc_class` — byte offsets of `isa`, `dtable`, and everything else. Is the struct already defined such that moving dtable requires renaming or just reordering?
2. Who else reads `struct objc_class` fields by offset? Any asm that hardcodes offsets (check `asmconstants.h`)?
3. Is `struct objc_class` exposed to consumers via public headers (`objc/objc-class.h`)? If yes, reordering is an ABI break of a publicly-visible struct.
4. Is there prior art in Apple's runtime? Apple's objc4 moved to non-pointer isa long ago; the closest analogue here is just keeping the hot fields adjacent.
5. Measured impact: how many msg_send_cold-class calls per second on a representative workload, and what's the L1/L2 miss delta? Instrument with perf counters if available.

**Deliverable:** `docs/spikes/2026-04-13-dtable-cache-line.md`.

**Estimated effort:** 1 day reading, 0.5 day benchmarking, 0.5 day writing.

---

### Spike B4: Glyph caching for CoreText/libs-opal

**Target:** `libs-opal/Source/OpalText/` (whatever files do glyph rasterization via Cairo/FreeType), `libs-opal/Source/OpalGraphics/CGFont.m`.

**Problem:** Every string draw call currently rasterizes glyphs from scratch. A cache keyed on `(font, glyph index, size, transform)` would let repeat draws hit a bitmap cache, dropping per-call cost from "rasterize all glyphs" to "blit cached bitmaps".

**Research questions:**
1. Inventory the glyph rasterization path: which function ends up calling Cairo's `cairo_show_glyphs` or FreeType directly?
2. Does Cairo itself already cache glyph bitmaps internally? (It does — `cairo_scaled_font` caches glyphs per font object.) If yes, the real win may be ensuring callers reuse the same `cairo_scaled_font` instance rather than adding a new cache on top. Verify with a Cairo-level trace.
3. Where are `cairo_scaled_font_t` objects created and destroyed? Per-draw, per-CGContext, or per-CGFont?
4. What is the actual measured time breakdown of a typical string draw — rasterization vs layout vs Cairo surface blit? Build a micro-benchmark before designing a cache.

**Deliverable:** `docs/spikes/2026-04-13-glyph-caching.md`. This spike may conclude NO-GO if Cairo already caches and the real problem is caller-side font reuse.

**Estimated effort:** 2 days reading + tracing, 1 day benchmarking, 0.5 day writing.

---

### Spike B5: `GSSmallDictionary` for N <= 4 entries (libs-base)

**Target:** `libs-base/Source/NSDictionary.m`, `libs-base/Source/GSDictionary.m`, `libs-base/Source/NSConcreteDictionary.m` (if the concrete class hierarchy is split).

**Problem:** The default `GSDictionary` uses the full hash-table machinery even for dictionaries with 1-4 entries (the common case for things like `@{ @"key": value }` one-shot constructions). A linear-probe small variant that stores `(key, value)` pairs in an inline array avoids the hash computation, bucket allocation, and pointer chasing.

**Research questions:**
1. Is there an existing small-dict class (`GSSmallDict`, `GSInlineDict`, `NSConstantDict`)? How is dispatch between small and large currently chosen — compile-time constants, runtime promotion, class cluster?
2. What percentage of NSDictionary allocations in a representative GNUstep workload have `count <= 4`? Instrument `+alloc` and report histogram.
3. Lookup performance for small N: when does the linear-probe small dict beat the hashed version? Benchmark N=1,2,3,4,8,16.
4. Promotion path: if an inline dict grows past 4, does it need to realize to a full GSDictionary in place, or is it immutable and realization only happens via `-mutableCopy`?
5. Class-cluster dispatch cost: `+alloc` on NSDictionary already dispatches via the cluster; adding one more concrete class shouldn't change allocation cost, but verify.

**Deliverable:** `docs/spikes/2026-04-13-gs-small-dictionary.md`.

**Estimated effort:** 1 day reading, 1 day instrumentation + benchmarking, 0.5 day writing.

---

### Spike B6: Pool page recycling (libobjc2)

**Target:** `libobjc2/arc.mm` AutoreleasePoolPage allocation, `libobjc2/pool.hh`.

**Problem:** Autorelease pool pages are allocated on demand and freed on drain. High-throughput workloads that create short-lived pools thrash the allocator. A thread-local free list of released pages lets the next pool reuse a page instead of round-tripping through `malloc/free`.

**Research questions:**
1. Current allocation path: read `AutoreleasePoolPage::allocate`, `AutoreleasePoolPage::releasePage` (or whatever the current symbol names are — the implementation is in `arc.mm` around the `AutoreleasePoolPage` class). Is the page size fixed? Is allocation via `malloc`, `mmap`, or a custom slab?
2. Thread-local free list size: what's the right cap? A free list of 4 pages (at 4KB each = 16KB TLS overhead) likely captures most recycling opportunities without holding arbitrarily large state.
3. Is there existing pool-page code that resembles a free list? (Apple's objc4 uses a fast path called `hotPageAllocation` that can be referenced for shape only — do not copy code.)
4. Memory pressure interaction: does the free list need a high-water-mark reclaim path, or can we trust the OS to reclaim under pressure if we don't cap the list?
5. Measured impact: what's the current `malloc` rate attributable to pool pages on a typical workload? Instrument with DTrace/perf or a custom counter.

**Deliverable:** `docs/spikes/2026-04-13-pool-page-recycling.md`.

**Estimated effort:** 1 day reading, 1 day instrumentation, 0.5 day writing.

---

### Spike B7: NSZone removal (libs-base)

**Target:** `libs-base/Source/NSZone.m`, plus every caller of `NSZoneMalloc`, `NSZoneFromPointer`, `NSZoneFree`, `NSDefaultMallocZone`, `-zone` method, `+allocWithZone:` (which is nearly every NSObject subclass).

**Problem:** NSZone was Apple's attempt at sub-allocator regions in the OpenStep era and has been deprecated for over 20 years. libs-base still carries the full API surface and every class implements `+allocWithZone:`. The zone parameter is almost always ignored by callers and always ignored by the system malloc on all platforms libs-base targets. Keeping the API costs a function pointer in every NSObject vtable (via allocWithZone:) and adds a parameter to most allocation paths.

**Research questions:**
1. Is `+allocWithZone:` actually overridden meaningfully anywhere, or is it always `{return [self alloc]; }`? Audit all overrides.
2. What's the ABI impact of removing `-zone` as a public method? If we keep the method but have it return `NULL`, do any consumers crash? (Likely not — most check for non-NULL.)
3. Can this be done as a compatibility shim — keep the API, forward all zone operations to default malloc — without actually removing anything? That's a much smaller change and captures most of the maintenance benefit.
4. Does the Apple Foundation reference implementation still support NSZone on modern macOS? (Yes — as a no-op compatibility shim, same approach.)
5. Binary size delta from removing the NSZone implementation: estimate by measuring `NSZone.o` object size and subtracting the compatibility-shim replacement size.

**Deliverable:** `docs/spikes/2026-04-13-nszone-removal.md`. This spike is the most likely to conclude "NO-GO — ship the compatibility shim instead" since removing NSZone offers marginal perf gain at high ABI cost.

**Estimated effort:** 0.5 day reading (NSZone.m is small), 1 day auditing overrides across libs-base, 0.5 day writing.

---

## Out of Scope (documented for future feature work)

These were noted during the audit but are NOT part of this follow-up plan. They are feature additions or research detours outside the perf-optimization scope.

- **CAKeyframeAnimation / CASpringAnimation implementations (libs-quartzcore).** These are unimplemented feature stubs, not audit fixes. Tracked as feature work, not performance work. If needed for Core Animation completeness, file a separate feature spec.
- **CGContext state caching (libs-opal, `Source/OpalGraphics/CGContext.m`).** The audit plan at `2026-04-12-fix-graphics.md:1290` documented this as "not cost-effective — CGContext is a thin Cairo wrapper; tracking every state variable would require invasive changes for uncertain gain." That decision stands. The TODO comment in the source code is the permanent record.
- **CALayer AR-Q7 sublayer-aware rasterize size (libs-quartzcore, `Source/CARenderer.m:836`).** The current best-effort code uses the layer's own bounds and falls back to 512×512 only when bounds are degenerate. Full sublayer-aware sizing (walking the sublayer tree, computing union bounds with transforms applied) is a larger CA refactor out of perf-optimization scope. The TODO in CARenderer.m is the permanent record.
- **268 pre-existing TODO/FIXME/HACK markers across libs-gui** (audit finding RB-B8). These are long-standing technical debt from upstream GNUstep, not audit-introduced. Tracked as upstream debt, not audit scope.

---

## Sequencing Recommendation

**Week 1:** Pre-task (docs fix) + Task A1 (NSRunLoop timer cache) + Task A2 (GSHashTable tombstone). These are fully specified and low-risk. Target: three commits landed, all 33+ regression tests passing, runloop benchmark showing measurable delta on high-N cases.

**Week 2-3:** Spikes B1, B2, B3 (the three libobjc2 / libs-base architectural pieces). Dispatch each spike as a fresh subagent with the spike template above and the target files listed. Review design docs before promoting any to implementation.

**Week 4+:** Spikes B4, B5, B6, B7 and follow-up implementation plans for whichever spikes clear review. Most likely outcomes:
- B1 (per-class cache version): GO, medium-risk, high-value implementation.
- B2 (tagged-pointer NSString): GO if small-obj infra exists, otherwise DEEP-DIVE into adding it.
- B3 (dtable cache-line): GO, low-risk mechanical change pending ABI audit.
- B4 (glyph caching): likely NO-GO with redirect to "ensure callers reuse cairo_scaled_font".
- B5 (small dict): GO with a benchmark-first validation.
- B6 (pool page recycling): GO, medium value.
- B7 (NSZone removal): likely NO-GO with redirect to compatibility shim.

---

## Execution Checklist

Each Part A task must satisfy before marking complete:

- [ ] All 32+ existing regression tests still pass (`make tests` from `instrumentation/`).
- [ ] The new test for the task passes.
- [ ] Relevant benchmark re-run; delta recorded in task commit message or in `instrumentation/benchmarks/results/`.
- [ ] Repo commit pushed to its respective fork (libs-base → DTW-Thalion/libs-base; libs-corebase → DTW-Thalion/libs-corebase).
- [ ] Corresponding instrumentation commit (new test / benchmark) pushed to DTW-Thalion/gnustep-audit main.
- [ ] `docs/AUDIT-SUMMARY.md` updated if the task closes an item in §Completion Status.

Each Part B spike must satisfy before marking complete:

- [ ] Spike doc written covering all 7 sections of the spike template.
- [ ] Decision field filled: GO / NO-GO / NEEDS-DISCUSSION.
- [ ] If GO, a follow-up implementation plan file is created (empty header is fine) to track the work.
- [ ] Spike doc committed to `gnustep-audit/docs/spikes/` and pushed.
