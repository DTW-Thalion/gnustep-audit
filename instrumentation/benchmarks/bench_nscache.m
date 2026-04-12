/*
 * bench_nscache.m - NSCache get/set throughput benchmark
 *
 * Measures NSCache performance with 10 and 10000 entries.
 * Demonstrates O(n) vs O(1) behavior in eviction.
 *
 * Targets: PF-1 (linked list rewrite to hash map)
 *
 * Usage: ./bench_nscache [--json]
 */

#import <Foundation/Foundation.h>
#include "bench_harness.h"

#define ITERS_SMALL  500000
#define ITERS_LARGE  50000
#define SMALL_SIZE   10
#define LARGE_SIZE   10000

int main(int argc, char *argv[]) {
    int json = (argc > 1 && strcmp(argv[1], "--json") == 0);

    @autoreleasepool {
        /* Pre-generate keys and values */
        NSMutableArray *keys = [NSMutableArray arrayWithCapacity:LARGE_SIZE];
        NSMutableArray *vals = [NSMutableArray arrayWithCapacity:LARGE_SIZE];
        for (int i = 0; i < LARGE_SIZE; i++) {
            [keys addObject:[NSString stringWithFormat:@"key_%d", i]];
            [vals addObject:[NSNumber numberWithInt:i]];
        }

        /* --- Small cache benchmarks --- */
        {
            NSCache *cache = [[NSCache alloc] init];
            [cache setCountLimit:SMALL_SIZE];

            /* Populate */
            for (int i = 0; i < SMALL_SIZE; i++) {
                [cache setObject:[vals objectAtIndex:(NSUInteger)i]
                          forKey:[keys objectAtIndex:(NSUInteger)i]];
            }

            /* Benchmark 1: Small cache hit */
            NSString *hitKey = [keys objectAtIndex:SMALL_SIZE / 2];
            if (json) {
                BENCH_JSON("nscache_get_small_hit", ITERS_SMALL, {
                    (void)[cache objectForKey:hitKey];
                });
            } else {
                BENCH("nscache_get_small_hit", ITERS_SMALL, {
                    (void)[cache objectForKey:hitKey];
                });
            }

            /* Benchmark 2: Small cache miss */
            NSString *missKey = @"nonexistent";
            if (json) {
                BENCH_JSON("nscache_get_small_miss", ITERS_SMALL, {
                    (void)[cache objectForKey:missKey];
                });
            } else {
                BENCH("nscache_get_small_miss", ITERS_SMALL, {
                    (void)[cache objectForKey:missKey];
                });
            }

            /* Benchmark 3: Small cache set (overwrite existing) */
            NSNumber *newVal = [NSNumber numberWithInt:999];
            if (json) {
                BENCH_JSON("nscache_set_small", ITERS_SMALL, {
                    [cache setObject:newVal forKey:hitKey];
                });
            } else {
                BENCH("nscache_set_small", ITERS_SMALL, {
                    [cache setObject:newVal forKey:hitKey];
                });
            }

            [cache release];
        }

        /* --- Large cache benchmarks --- */
        {
            NSCache *cache = [[NSCache alloc] init];
            [cache setCountLimit:LARGE_SIZE];

            /* Populate */
            for (int i = 0; i < LARGE_SIZE; i++) {
                [cache setObject:[vals objectAtIndex:(NSUInteger)i]
                          forKey:[keys objectAtIndex:(NSUInteger)i]];
            }

            /* Benchmark 4: Large cache hit */
            NSString *hitKey = [keys objectAtIndex:LARGE_SIZE / 2];
            if (json) {
                BENCH_JSON("nscache_get_large_hit", ITERS_LARGE, {
                    (void)[cache objectForKey:hitKey];
                });
            } else {
                BENCH("nscache_get_large_hit", ITERS_LARGE, {
                    (void)[cache objectForKey:hitKey];
                });
            }

            /* Benchmark 5: Large cache miss */
            NSString *missKey = @"nonexistent";
            if (json) {
                BENCH_JSON("nscache_get_large_miss", ITERS_LARGE, {
                    (void)[cache objectForKey:missKey];
                });
            } else {
                BENCH("nscache_get_large_miss", ITERS_LARGE, {
                    (void)[cache objectForKey:missKey];
                });
            }

            /* Benchmark 6: Large cache set causing eviction */
            if (json) {
                BENCH_JSON("nscache_set_large_evict", ITERS_LARGE, {
                    @autoreleasepool {
                        NSString *k = [NSString stringWithFormat:@"new_%d",
                                       _bench_i];
                        [cache setObject:[NSNumber numberWithInt:_bench_i]
                                  forKey:k];
                    }
                });
            } else {
                BENCH("nscache_set_large_evict", ITERS_LARGE, {
                    @autoreleasepool {
                        NSString *k = [NSString stringWithFormat:@"new_%d",
                                       _bench_i];
                        [cache setObject:[NSNumber numberWithInt:_bench_i]
                                  forKey:k];
                    }
                });
            }

            [cache release];
        }
    }

    return 0;
}
