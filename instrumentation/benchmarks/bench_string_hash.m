/*
 * bench_string_hash.m - String hash computation benchmark
 *
 * Measures hash computation throughput for short (5 char),
 * medium (50 char), and long (500 char) strings.
 *
 * Targets: hash optimization
 *
 * Usage: ./bench_string_hash [--json]
 */

#import <Foundation/Foundation.h>
#include "bench_harness.h"

#define ITERATIONS 5000000

static NSString *makeString(int length) {
    char *buf = (char *)malloc((size_t)length + 1);
    for (int i = 0; i < length; i++) {
        buf[i] = 'a' + (i % 26);
    }
    buf[length] = '\0';
    NSString *str = [[NSString alloc] initWithUTF8String:buf];
    free(buf);
    return str;
}

int main(int argc, char *argv[]) {
    int json = (argc > 1 && strcmp(argv[1], "--json") == 0);

    @autoreleasepool {
        NSString *shortStr  = makeString(5);
        NSString *medStr    = makeString(50);
        NSString *longStr   = makeString(500);

        /* Benchmark 1: Short string hash (5 chars) */
        if (json) {
            BENCH_JSON("hash_short_5", ITERATIONS, {
                (void)[shortStr hash];
            });
        } else {
            BENCH("hash_short_5", ITERATIONS, {
                (void)[shortStr hash];
            });
        }

        /* Benchmark 2: Medium string hash (50 chars) */
        if (json) {
            BENCH_JSON("hash_medium_50", ITERATIONS, {
                (void)[medStr hash];
            });
        } else {
            BENCH("hash_medium_50", ITERATIONS, {
                (void)[medStr hash];
            });
        }

        /* Benchmark 3: Long string hash (500 chars) */
        if (json) {
            BENCH_JSON("hash_long_500", ITERATIONS, {
                (void)[longStr hash];
            });
        } else {
            BENCH("hash_long_500", ITERATIONS, {
                (void)[longStr hash];
            });
        }

        /* Benchmark 4: Hash equality check (same-hash strings) */
        NSString *shortCopy = [shortStr copy];
        if (json) {
            BENCH_JSON("hash_equality_short", ITERATIONS, {
                (void)([shortStr hash] == [shortCopy hash]);
            });
        } else {
            BENCH("hash_equality_short", ITERATIONS, {
                (void)([shortStr hash] == [shortCopy hash]);
            });
        }

        [shortCopy release];
        [shortStr release];
        [medStr release];
        [longStr release];
    }

    return 0;
}
