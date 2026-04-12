/*
 * bench_autorelease.m - Autorelease pool push/pop/drain benchmark
 *
 * Measures autorelease pool performance with varying object counts
 * and nested pool depths.
 *
 * Targets: pool page recycling optimization
 *
 * Usage: ./bench_autorelease [--json]
 */

#import <Foundation/Foundation.h>
#include "bench_harness.h"

#define ITERS_SMALL   100000
#define ITERS_MEDIUM  10000
#define ITERS_LARGE   1000
#define ITERS_NESTED  10000

int main(int argc, char *argv[]) {
    int json = (argc > 1 && strcmp(argv[1], "--json") == 0);

    @autoreleasepool {
        /* Benchmark 1: Pool with 1 object */
        if (json) {
            BENCH_JSON("autorelease_1_obj", ITERS_SMALL, {
                @autoreleasepool {
                    [[[NSObject alloc] init] autorelease];
                }
            });
        } else {
            BENCH("autorelease_1_obj", ITERS_SMALL, {
                @autoreleasepool {
                    [[[NSObject alloc] init] autorelease];
                }
            });
        }

        /* Benchmark 2: Pool with 10 objects */
        if (json) {
            BENCH_JSON("autorelease_10_obj", ITERS_MEDIUM, {
                @autoreleasepool {
                    for (int j = 0; j < 10; j++) {
                        [[[NSObject alloc] init] autorelease];
                    }
                }
            });
        } else {
            BENCH("autorelease_10_obj", ITERS_MEDIUM, {
                @autoreleasepool {
                    for (int j = 0; j < 10; j++) {
                        [[[NSObject alloc] init] autorelease];
                    }
                }
            });
        }

        /* Benchmark 3: Pool with 100 objects */
        if (json) {
            BENCH_JSON("autorelease_100_obj", ITERS_MEDIUM, {
                @autoreleasepool {
                    for (int j = 0; j < 100; j++) {
                        [[[NSObject alloc] init] autorelease];
                    }
                }
            });
        } else {
            BENCH("autorelease_100_obj", ITERS_MEDIUM, {
                @autoreleasepool {
                    for (int j = 0; j < 100; j++) {
                        [[[NSObject alloc] init] autorelease];
                    }
                }
            });
        }

        /* Benchmark 4: Pool with 1000 objects */
        if (json) {
            BENCH_JSON("autorelease_1000_obj", ITERS_LARGE, {
                @autoreleasepool {
                    for (int j = 0; j < 1000; j++) {
                        [[[NSObject alloc] init] autorelease];
                    }
                }
            });
        } else {
            BENCH("autorelease_1000_obj", ITERS_LARGE, {
                @autoreleasepool {
                    for (int j = 0; j < 1000; j++) {
                        [[[NSObject alloc] init] autorelease];
                    }
                }
            });
        }

        /* Benchmark 5: Nested pools (depth 5) with 10 objects each */
        if (json) {
            BENCH_JSON("autorelease_nested_5", ITERS_NESTED, {
                @autoreleasepool {
                    for (int j = 0; j < 10; j++)
                        [[[NSObject alloc] init] autorelease];
                    @autoreleasepool {
                        for (int j = 0; j < 10; j++)
                            [[[NSObject alloc] init] autorelease];
                        @autoreleasepool {
                            for (int j = 0; j < 10; j++)
                                [[[NSObject alloc] init] autorelease];
                            @autoreleasepool {
                                for (int j = 0; j < 10; j++)
                                    [[[NSObject alloc] init] autorelease];
                                @autoreleasepool {
                                    for (int j = 0; j < 10; j++)
                                        [[[NSObject alloc] init] autorelease];
                                }
                            }
                        }
                    }
                }
            });
        } else {
            BENCH("autorelease_nested_5", ITERS_NESTED, {
                @autoreleasepool {
                    for (int j = 0; j < 10; j++)
                        [[[NSObject alloc] init] autorelease];
                    @autoreleasepool {
                        for (int j = 0; j < 10; j++)
                            [[[NSObject alloc] init] autorelease];
                        @autoreleasepool {
                            for (int j = 0; j < 10; j++)
                                [[[NSObject alloc] init] autorelease];
                            @autoreleasepool {
                                for (int j = 0; j < 10; j++)
                                    [[[NSObject alloc] init] autorelease];
                                @autoreleasepool {
                                    for (int j = 0; j < 10; j++)
                                        [[[NSObject alloc] init] autorelease];
                                }
                            }
                        }
                    }
                }
            });
        }

        /* Benchmark 6: Rapid pool push/pop with no objects (overhead) */
        if (json) {
            BENCH_JSON("autorelease_empty_pool", ITERS_SMALL, {
                @autoreleasepool { }
            });
        } else {
            BENCH("autorelease_empty_pool", ITERS_SMALL, {
                @autoreleasepool { }
            });
        }
    }

    return 0;
}
