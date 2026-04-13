/*
 * bench_dict_create.m - Dictionary construction benchmark
 *
 * Measures NSDictionary construction throughput at several small N and at
 * larger N that fall through to the default GSDictionary path. This is
 * the PRIMARY success metric for B5.1 (GSInlineDict) per the spike §4.5.
 *
 * For each N we build a tight loop of +[NSDictionary
 * dictionaryWithObjects:forKeys:count:] calls, wrapped in
 * @autoreleasepool to drain the intermediate dicts. Keys and values are
 * fresh NSNumber / NSString objects constructed once outside the hot
 * path so the measurement captures dictionary construction rather than
 * key/value allocation.
 *
 * Usage: ./bench_dict_create [--json]
 */

#import <Foundation/Foundation.h>
#include "bench_harness.h"

#define ITERS_SMALL  2000000
#define ITERS_LARGE  500000

static void run_case(const char *name, int json, NSUInteger n,
                     id keys[], id vals[], int iters) {
    if (json) {
        BENCH_JSON(name, iters, {
            @autoreleasepool {
                (void)[NSDictionary dictionaryWithObjects: vals
                                                  forKeys: keys
                                                    count: n];
            }
        });
    } else {
        BENCH(name, iters, {
            @autoreleasepool {
                (void)[NSDictionary dictionaryWithObjects: vals
                                                  forKeys: keys
                                                    count: n];
            }
        });
    }
}

int main(int argc, char *argv[]) {
    int json = (argc > 1 && strcmp(argv[1], "--json") == 0);

    @autoreleasepool {
        /* Prebuild up to 16 keys and values. Retained so they outlive any
         * inner autorelease drains. */
        id keys[16];
        id vals[16];
        for (int i = 0; i < 16; i++) {
            keys[i] = [[NSString stringWithFormat: @"key_%d", i] retain];
            vals[i] = [[NSNumber numberWithInt: i] retain];
        }

        run_case("dict_create_1",  json, 1,  keys, vals, ITERS_SMALL);
        run_case("dict_create_2",  json, 2,  keys, vals, ITERS_SMALL);
        run_case("dict_create_3",  json, 3,  keys, vals, ITERS_SMALL);
        run_case("dict_create_4",  json, 4,  keys, vals, ITERS_SMALL);
        run_case("dict_create_5",  json, 5,  keys, vals, ITERS_SMALL);
        run_case("dict_create_8",  json, 8,  keys, vals, ITERS_LARGE);
        run_case("dict_create_16", json, 16, keys, vals, ITERS_LARGE);

        for (int i = 0; i < 16; i++) {
            [keys[i] release];
            [vals[i] release];
        }
    }

    return 0;
}
