/*
 * bench_retain_release.m - Retain/release cycle throughput benchmark
 *
 * Measures single-threaded retain+release pair throughput and
 * autorelease pool push/drain performance.
 *
 * Targets: PF-7 (atomic load fix for retain count)
 *
 * Usage: ./bench_retain_release [--json]
 */

#import <Foundation/Foundation.h>
#include "bench_harness.h"

#define ITERATIONS     10000000
#define POOL_OBJECTS   1000
#define POOL_ITERS     10000

int main(int argc, char *argv[]) {
    int json = (argc > 1 && strcmp(argv[1], "--json") == 0);

    @autoreleasepool {
        id obj = [[NSObject alloc] init];

        /* Benchmark 1: retain + release pair */
        if (json) {
            BENCH_JSON("retain_release_pair", ITERATIONS, {
                [obj retain];
                [obj release];
            });
        } else {
            BENCH("retain_release_pair", ITERATIONS, {
                [obj retain];
                [obj release];
            });
        }

        /* Benchmark 2: retain only (accumulate, then bulk release) */
        if (json) {
            BENCH_JSON("retain_only", ITERATIONS, {
                [obj retain];
            });
        } else {
            BENCH("retain_only", ITERATIONS, {
                [obj retain];
            });
        }
        /* Balance the retains */
        for (int i = 0; i < ITERATIONS; i++) {
            [obj release];
        }

        /* Benchmark 3: autorelease pool push/drain with objects */
        if (json) {
            BENCH_JSON("autorelease_pool_drain", POOL_ITERS, {
                @autoreleasepool {
                    for (int j = 0; j < POOL_OBJECTS; j++) {
                        [[[NSObject alloc] init] autorelease];
                    }
                }
            });
        } else {
            BENCH("autorelease_pool_drain", POOL_ITERS, {
                @autoreleasepool {
                    for (int j = 0; j < POOL_OBJECTS; j++) {
                        [[[NSObject alloc] init] autorelease];
                    }
                }
            });
        }

        /* Benchmark 4: empty autorelease pool push/pop */
        if (json) {
            BENCH_JSON("autorelease_pool_empty", ITERATIONS, {
                @autoreleasepool {
                    /* empty - measures pool push/pop overhead */
                }
            });
        } else {
            BENCH("autorelease_pool_empty", ITERATIONS, {
                @autoreleasepool {
                    /* empty - measures pool push/pop overhead */
                }
            });
        }

        [obj release];
    }

    return 0;
}
