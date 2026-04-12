/*
 * bench_cfarray_append.m - CFMutableArray sequential append benchmark
 *
 * Measures the cost of sequential appends to CFMutableArray.
 * Tests 100000 appends to reveal growth strategy (linear vs geometric).
 *
 * Targets: PF-1 (geometric growth for CFMutableArray)
 *
 * Usage: ./bench_cfarray_append [--json]
 */

#import <Foundation/Foundation.h>
#include "bench_harness.h"

#define APPEND_COUNT 100000
#define ITERATIONS   100

int main(int argc, char *argv[]) {
    int json = (argc > 1 && strcmp(argv[1], "--json") == 0);

    @autoreleasepool {
        id sentinel = [[NSObject alloc] init];

        /* Benchmark 1: NSMutableArray sequential append */
        if (json) {
            BENCH_JSON("nsarray_append_100k", ITERATIONS, {
                @autoreleasepool {
                    NSMutableArray *arr = [NSMutableArray array];
                    for (int j = 0; j < APPEND_COUNT; j++) {
                        [arr addObject:sentinel];
                    }
                }
            });
        } else {
            BENCH("nsarray_append_100k", ITERATIONS, {
                @autoreleasepool {
                    NSMutableArray *arr = [NSMutableArray array];
                    for (int j = 0; j < APPEND_COUNT; j++) {
                        [arr addObject:sentinel];
                    }
                }
            });
        }

        /* Benchmark 2: NSMutableArray with capacity hint */
        if (json) {
            BENCH_JSON("nsarray_append_100k_capacity", ITERATIONS, {
                @autoreleasepool {
                    NSMutableArray *arr =
                        [NSMutableArray arrayWithCapacity:APPEND_COUNT];
                    for (int j = 0; j < APPEND_COUNT; j++) {
                        [arr addObject:sentinel];
                    }
                }
            });
        } else {
            BENCH("nsarray_append_100k_capacity", ITERATIONS, {
                @autoreleasepool {
                    NSMutableArray *arr =
                        [NSMutableArray arrayWithCapacity:APPEND_COUNT];
                    for (int j = 0; j < APPEND_COUNT; j++) {
                        [arr addObject:sentinel];
                    }
                }
            });
        }

        /* Benchmark 3: Insert at beginning (worst case for contiguous) */
        if (json) {
            BENCH_JSON("nsarray_insert_front_10k", 10, {
                @autoreleasepool {
                    NSMutableArray *arr = [NSMutableArray array];
                    for (int j = 0; j < 10000; j++) {
                        [arr insertObject:sentinel atIndex:0];
                    }
                }
            });
        } else {
            BENCH("nsarray_insert_front_10k", 10, {
                @autoreleasepool {
                    NSMutableArray *arr = [NSMutableArray array];
                    for (int j = 0; j < 10000; j++) {
                        [arr insertObject:sentinel atIndex:0];
                    }
                }
            });
        }

        /* Benchmark 4: removeLastObject (amortized cost) */
        if (json) {
            BENCH_JSON("nsarray_remove_last_100k", ITERATIONS, {
                @autoreleasepool {
                    NSMutableArray *arr =
                        [NSMutableArray arrayWithCapacity:APPEND_COUNT];
                    for (int j = 0; j < APPEND_COUNT; j++) {
                        [arr addObject:sentinel];
                    }
                    for (int j = 0; j < APPEND_COUNT; j++) {
                        [arr removeLastObject];
                    }
                }
            });
        } else {
            BENCH("nsarray_remove_last_100k", ITERATIONS, {
                @autoreleasepool {
                    NSMutableArray *arr =
                        [NSMutableArray arrayWithCapacity:APPEND_COUNT];
                    for (int j = 0; j < APPEND_COUNT; j++) {
                        [arr addObject:sentinel];
                    }
                    for (int j = 0; j < APPEND_COUNT; j++) {
                        [arr removeLastObject];
                    }
                }
            });
        }

        [sentinel release];
    }

    return 0;
}
