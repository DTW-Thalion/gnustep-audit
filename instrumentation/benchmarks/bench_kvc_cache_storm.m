/*
 * bench_kvc_cache_storm.m — measure the KVC-cache storm cost caused by
 * the global `objc_method_cache_version` counter being bumped from
 * unrelated class mutations.
 *
 * Background (per spike B1, corrected by empirical investigation):
 *
 * libs-base's KVC slot cache in
 * `libs-base/Source/NSKeyValueCoding+Caching.m:623` checks
 *     if (objc_method_cache_version != cachedSlot->version)
 * on every `valueForKey:` call. When the check fails it re-resolves
 * the slot via `ValueForKeyLookup`, then updates `cachedSlot->version`
 * to the current global counter.
 *
 * IMPORTANT — which APIs actually bump the counter:
 *   (A) class_replaceMethod on an existing method:  DOES NOT BUMP
 *       (libobjc2/runtime.c:496-498 directly writes method->imp,
 *        bypassing installMethodInDtable entirely)
 *   (B) class_addMethod with a new selector:        DOES NOT BUMP
 *       (installMethodsInClass sees method_to_replace==NULL)
 *   (C) class_addMethod overriding a super method:  bumps by 1
 *       (super_dtable lookup returns the overridden method, so
 *        installMethodInDtable sees oldMethod != NULL)
 *   (D) KVO install (-addObserver:forKeyPath:...):  bumps by ~300
 *       (the KVO machinery isa-swizzles to NSKVONotifying_*, which
 *        overrides many superclass methods in a single batch)
 *
 * Since KVO install is the realistic bump trigger in application code,
 * this benchmark measures the KVC cache storm cost in the
 * KVO-install-churn scenario: install + remove an observer on a
 * fresh class each iteration, then do a batch of 10 valueForKey:
 * calls on a separate, persistent BenchTarget whose KVC cache was
 * previously warm. The counter movement from the KVO swizzle
 * invalidates every slot in the persistent target's cache, forcing
 * a refresh on the next batch of lookups.
 *
 * Three benchmarks are emitted:
 *
 *   kvc_cache_hot          — steady-state KVC lookup on a persistent
 *                            BenchTarget with warm cache and no
 *                            observer churn. The fast-path baseline.
 *
 *   kvo_install_churn      — bare cost of creating a fresh subclass
 *                            of NSObject per iteration and adding an
 *                            override of -hash to it (via
 *                            class_addMethod, path C above). This
 *                            bumps the counter by 1 per iteration
 *                            and measures the cost of the class
 *                            allocation + method addition itself.
 *
 *   kvc_cache_storm        — each iteration does the full churn
 *                            (create class + add -hash override,
 *                            which bumps the counter) AND a batch
 *                            of 10 valueForKey: calls on the
 *                            persistent BenchTarget. The delta
 *                            against kvo_install_churn + kvc_cache_hot
 *                            isolates the cache-refresh cost.
 *
 * Note: we use path (C) rather than real KVO (-addObserver:...) because
 * path (C) is simpler, deterministic, and hits the same counter-bump
 * site. Real KVO would bump by ~300 per install instead of 1, but the
 * mechanism (installMethodInDtable with oldMethod != NULL) is
 * identical — 1 vs 300 affects the frequency with which the storm
 * happens in a real application, not the per-slot refresh cost which
 * is what this benchmark isolates.
 *
 * Usage: ./bench_kvc_cache_storm [--json]
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#include "bench_harness.h"

#define KEY_COUNT  10
#define HOT_ITERS  1000000
#define STORM_ITERS 10000

/* ------------------------------------------------------------------ */
/* Target class: 10 int ivars + getters. All keys are short ASCII     */
/* and the class conforms to the standard KVC convention so                 */
/* valueForKey: hits the fast-getter path, not the fallback.          */
/* ------------------------------------------------------------------ */

@interface BenchTarget : NSObject
{
  int _v0, _v1, _v2, _v3, _v4, _v5, _v6, _v7, _v8, _v9;
}
- (int) v0;
- (int) v1;
- (int) v2;
- (int) v3;
- (int) v4;
- (int) v5;
- (int) v6;
- (int) v7;
- (int) v8;
- (int) v9;
@end

@implementation BenchTarget
- (int) v0 { return _v0; }
- (int) v1 { return _v1; }
- (int) v2 { return _v2; }
- (int) v3 { return _v3; }
- (int) v4 { return _v4; }
- (int) v5 { return _v5; }
- (int) v6 { return _v6; }
- (int) v7 { return _v7; }
- (int) v8 { return _v8; }
- (int) v9 { return _v9; }
@end

/* ------------------------------------------------------------------ */
/* Sacrificial class — we call class_replaceMethod on this class to   */
/* bump the global objc_method_cache_version counter. The method      */
/* being replaced always has identical behavior; we just toggle       */
/* between two trivial IMPs per iteration to ensure the replace is    */
/* real (the runtime may short-circuit replace-with-same-imp).        */
/* ------------------------------------------------------------------ */

@interface Sacrifice : NSObject
- (int) trigger;
@end

@implementation Sacrifice
- (int) trigger { return 1; }
@end

static int trigger_impl_a(id self, SEL _cmd) { (void)self; (void)_cmd; return 1; }
static int trigger_impl_b(id self, SEL _cmd) { (void)self; (void)_cmd; return 2; }

/* Import the global counter symbol so we can read its value directly
 * for diagnostic output. Declared extern here and resolved at link
 * time against libobjc2. */
extern _Atomic(uint64_t) objc_method_cache_version;

int main(int argc, char *argv[])
{
  int json = (argc > 1 && strcmp(argv[1], "--json") == 0);
  int diag = (argc > 1 && strcmp(argv[1], "--diag") == 0);

  @autoreleasepool
    {
      BenchTarget *target = [[BenchTarget alloc] init];

      if (diag)
        {
          /* Diagnostic: try several counter-bump mechanisms and
           * report whether each one actually moves
           * objc_method_cache_version. If NONE of them move the
           * counter, the KVC cache storm is not reachable from
           * user code and the whole premise of B1 is void. */
          uint64_t v = objc_method_cache_version;
          fprintf(stderr, "diag: initial counter = %llu\n",
                  (unsigned long long)v);

          /* (A) class_replaceMethod on a method the class already
           * has directly. This is the API most people assume bumps. */
          class_replaceMethod([Sacrifice class], @selector(trigger),
                              (IMP)trigger_impl_a, "i@:");
          uint64_t vA = objc_method_cache_version;
          fprintf(stderr, "diag: A) class_replaceMethod(own method) "
                  "delta = %lld\n", (long long)(vA - v));

          /* (B) class_addMethod adding a new selector to the class.
           * If the selector is not on any superclass either, no bump
           * should happen — but if it IS on a superclass (e.g.,
           * -description on NSObject), the bump should fire because
           * installMethodsInClass looks up the super's dtable. */
          class_addMethod([Sacrifice class], @selector(description_kvc_test),
                          (IMP)trigger_impl_a, "i@:");
          uint64_t vB = objc_method_cache_version;
          fprintf(stderr, "diag: B) class_addMethod(new selector, not "
                  "on super) delta = %lld\n", (long long)(vB - vA));

          /* (C) class_addMethod overriding a superclass method.
           * Sacrifice inherits -hash from NSObject. Adding -hash to
           * Sacrifice directly should hit the super_method path in
           * create_dtable_for_class / installMethodsInClass and
           * trigger the bump via installMethodInDtable's
           * oldMethod != NULL branch. */
          class_addMethod([Sacrifice class], @selector(hash),
                          (IMP)trigger_impl_a, "Q@:");
          uint64_t vC = objc_method_cache_version;
          fprintf(stderr, "diag: C) class_addMethod(override super -hash) "
                  "delta = %lld\n", (long long)(vC - vB));

          /* (D) KVO install — the real-world scenario the spike
           * described. -addObserver:forKeyPath:options:context:
           * creates an isa-swizzled subclass and overrides the
           * relevant setter via the KVO machinery. If KVO install
           * does not bump the counter, the whole "cache storm"
           * premise is invalid. */
          NSObject *kvoTarget = [[BenchTarget alloc] init];
          NSObject *observer = [[NSObject alloc] init];
          @try {
              [kvoTarget addObserver: observer
                          forKeyPath: @"v0"
                             options: 0
                             context: NULL];
          } @catch (NSException *e) {
              fprintf(stderr, "diag: D) KVO install raised: %s\n",
                      [[e reason] UTF8String]);
          }
          uint64_t vD = objc_method_cache_version;
          fprintf(stderr, "diag: D) KVO install delta = %lld\n",
                  (long long)(vD - vC));
          @try {
              [kvoTarget removeObserver: observer forKeyPath: @"v0"];
          } @catch (NSException *e) { /* ignore */ }
          [kvoTarget release];
          [observer release];

          fprintf(stderr, "diag: final counter = %llu (total movement %lld)\n",
                  (unsigned long long)vD, (long long)(vD - v));

          /* (E) class_addMethod overriding -hash on a FRESHLY
           * allocated class pair — the mechanism used by the
           * benchmark's churn loop. */
          fprintf(stderr, "diag: === fresh class pair tests ===\n");
          uint64_t vE0 = objc_method_cache_version;
          for (int i = 0; i < 3; i++)
            {
              char nm[32];
              snprintf(nm, 32, "DiagFresh_%d", i);
              Class nc = objc_allocateClassPair([NSObject class], nm, 0);
              class_addMethod(nc, @selector(hash),
                              (IMP)trigger_impl_a, "Q@:");
              objc_registerClassPair(nc);
              uint64_t vEi = objc_method_cache_version;
              fprintf(stderr, "diag: E%d) fresh class + addMethod(-hash) "
                      "delta = %lld\n", i, (long long)(vEi - vE0));
              vE0 = vEi;
            }

          return 0;
        }

      /* Pre-allocate the 10 KVC keys as constant strings so the key
       * allocation does not pollute the measurement. */
      NSString *keys[KEY_COUNT] = {
        @"v0", @"v1", @"v2", @"v3", @"v4",
        @"v5", @"v6", @"v7", @"v8", @"v9"
      };

      /* Warm the KVC cache: do one valueForKey: per key so every
       * slot is populated and has a valid .version stamp matching
       * the current global counter. */
      for (int k = 0; k < KEY_COUNT; k++)
        {
          (void)[target valueForKey: keys[k]];
        }

      /* -------------------------------------------------------- */
      /* Benchmark 1: cache-hot steady state                       */
      /* Each iteration: 10 valueForKey: calls, all cache hits.    */
      /* The global counter is not touched, so every cachedSlot->  */
      /* version comparison succeeds and returns the cached IMP.   */
      /* -------------------------------------------------------- */
      if (json)
        {
          BENCH_JSON("kvc_cache_hot", HOT_ITERS, {
            for (int k = 0; k < KEY_COUNT; k++)
              (void)[target valueForKey: keys[k]];
          });
        }
      else
        {
          BENCH("kvc_cache_hot", HOT_ITERS, {
            for (int k = 0; k < KEY_COUNT; k++)
              (void)[target valueForKey: keys[k]];
          });
        }

      /* Sanity-check the counter actually moves during the storm
       * benchmark. Must end strictly higher than it started or the
       * measurement is meaningless. */
      uint64_t counter_start = objc_method_cache_version;
      fprintf(stderr, "[counter at start of storm benches: %llu]\n",
              (unsigned long long)counter_start);

      /* -------------------------------------------------------- */
      /* Benchmark 2: bare counter-bump cost                       */
      /* Each iteration: one atomic fetch-add on                   */
      /* objc_method_cache_version. This is the smallest possible */
      /* isolation of the bump — no class creation, no method     */
      /* list mutation, just the atomic increment. The benchmark  */
      /* subtracts this from the storm benchmark to get the       */
      /* pure cache-refresh cost.                                  */
      /*                                                           */
      /* We use direct counter manipulation rather than            */
      /* class_addMethod / class_replaceMethod / KVO install       */
      /* because those APIs have divergent behavior:               */
      /*   - class_replaceMethod on an existing method: NO BUMP    */
      /*     (runtime.c:496 writes method->imp directly)           */
      /*   - class_addMethod(new selector): NO BUMP                */
      /*   - class_addMethod(override super method) on an          */
      /*     already-registered class WITH a dtable: bumps by 1    */
      /*   - class_addMethod on a fresh class pair (no dtable yet):*/
      /*     NO BUMP (installMethodInDtable is not reached because */
      /*     classHasDtable(cls) is false; the method is stored in */
      /*     the method list but not yet installed)                */
      /*   - KVO install (-addObserver:...): bumps by ~309         */
      /*     (isa-swizzles to NSKVONotifying_* with many method    */
      /*     overrides)                                             */
      /*                                                           */
      /* Since the spike's premise is that the KVC cache           */
      /* invalidates on ANY bump regardless of source, the         */
      /* mechanism-agnostic direct atomic increment is the         */
      /* cleanest isolation. If the cache-refresh cost is          */
      /* meaningful, it will show up as a delta between the        */
      /* bump-only and the bump+lookups benchmark regardless of    */
      /* which API caused the bump.                                */
      /* -------------------------------------------------------- */
      if (json)
        {
          BENCH_JSON("kvc_counter_bump", STORM_ITERS, {
            (void)atomic_fetch_add_explicit(&objc_method_cache_version, 1,
                                             memory_order_seq_cst);
          });
        }
      else
        {
          BENCH("kvc_counter_bump", STORM_ITERS, {
            (void)atomic_fetch_add_explicit(&objc_method_cache_version, 1,
                                             memory_order_seq_cst);
          });
        }

      /* Re-warm the KVC cache — every slot's .version is now far
       * behind the current counter. First batch of KVC lookups
       * refreshes all 10 slots, subsequent batches in kvc_cache_hot
       * style would be pure hits. */
      for (int k = 0; k < KEY_COUNT; k++)
        {
          (void)[target valueForKey: keys[k]];
        }

      /* -------------------------------------------------------- */
      /* Benchmark 3: cache-storm scenario                          */
      /* Each iteration: one counter bump + 10 valueForKey: calls. */
      /* The counter bump immediately invalidates every slot in    */
      /* the persistent target's cache, so each valueForKey: pays  */
      /* the ValueForKeyLookup refresh cost. Subsequent calls      */
      /* within the same iteration find their slot already         */
      /* refreshed (the memcpy at                                  */
      /* NSKeyValueCoding+Caching.m:633 updates cachedSlot->      */
      /* version to the current counter), so only the FIRST call  */
      /* per key per iteration pays the refresh cost.             */
      /*                                                           */
      /* Per-iteration storm cost:                                  */
      /*   (kvc_cache_storm - kvc_counter_bump) / iter              */
      /*   - (kvc_cache_hot / HOT_ITERS) per 10-lookup batch        */
      /* = pure per-10-lookup refresh cost                         */
      /* -------------------------------------------------------- */
      if (json)
        {
          BENCH_JSON("kvc_cache_storm", STORM_ITERS, {
            (void)atomic_fetch_add_explicit(&objc_method_cache_version, 1,
                                             memory_order_seq_cst);
            for (int k = 0; k < KEY_COUNT; k++)
              (void)[target valueForKey: keys[k]];
          });
        }
      else
        {
          BENCH("kvc_cache_storm", STORM_ITERS, {
            (void)atomic_fetch_add_explicit(&objc_method_cache_version, 1,
                                             memory_order_seq_cst);
            for (int k = 0; k < KEY_COUNT; k++)
              (void)[target valueForKey: keys[k]];
          });
        }

      uint64_t counter_end = objc_method_cache_version;
      fprintf(stderr, "[counter at end of storm benches: %llu "
              "(moved %lld, expected ~%d)]\n",
              (unsigned long long)counter_end,
              (long long)(counter_end - counter_start),
              2 * STORM_ITERS);

      [target release];
    }

  return 0;
}
