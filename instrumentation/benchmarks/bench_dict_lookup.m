/*
 * bench_dict_lookup.m - Dictionary lookup benchmark
 *
 * Measures NSDictionary lookup performance for small (4 entries) and
 * large (10000 entries) dictionaries. Tests objectForKey: throughput.
 *
 * Targets: small-dict optimization, hash function quality
 *
 * Usage: ./bench_dict_lookup [--json]
 */

#import <Foundation/Foundation.h>
#include "bench_harness.h"

#define ITERS_SMALL  5000000
#define ITERS_LARGE  1000000
#define SMALL_SIZE   4
#define LARGE_SIZE   10000

static NSDictionary *makeDictionary(int size) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithCapacity:(NSUInteger)size];
    for (int i = 0; i < size; i++) {
        NSString *key = [NSString stringWithFormat:@"key_%d", i];
        NSNumber *val = [NSNumber numberWithInt:i];
        [dict setObject:val forKey:key];
    }
    return [[dict copy] autorelease];
}

int main(int argc, char *argv[]) {
    int json = (argc > 1 && strcmp(argv[1], "--json") == 0);

    @autoreleasepool {
        /* Build dictionaries */
        NSDictionary *smallDict = [makeDictionary(SMALL_SIZE) retain];
        NSDictionary *largeDict = [makeDictionary(LARGE_SIZE) retain];

        /* Lookup keys (hit and miss) */
        NSString *hitKeySmall  = @"key_2";
        NSString *missKey      = @"nonexistent_key";
        NSString *hitKeyLarge  = @"key_5000";

        /* Benchmark 1: Small dict hit */
        if (json) {
            BENCH_JSON("dict_lookup_small_hit", ITERS_SMALL, {
                (void)[smallDict objectForKey:hitKeySmall];
            });
        } else {
            BENCH("dict_lookup_small_hit", ITERS_SMALL, {
                (void)[smallDict objectForKey:hitKeySmall];
            });
        }

        /* Benchmark 2: Small dict miss */
        if (json) {
            BENCH_JSON("dict_lookup_small_miss", ITERS_SMALL, {
                (void)[smallDict objectForKey:missKey];
            });
        } else {
            BENCH("dict_lookup_small_miss", ITERS_SMALL, {
                (void)[smallDict objectForKey:missKey];
            });
        }

        /* Benchmark 3: Large dict hit */
        if (json) {
            BENCH_JSON("dict_lookup_large_hit", ITERS_LARGE, {
                (void)[largeDict objectForKey:hitKeyLarge];
            });
        } else {
            BENCH("dict_lookup_large_hit", ITERS_LARGE, {
                (void)[largeDict objectForKey:hitKeyLarge];
            });
        }

        /* Benchmark 4: Large dict miss */
        if (json) {
            BENCH_JSON("dict_lookup_large_miss", ITERS_LARGE, {
                (void)[largeDict objectForKey:missKey];
            });
        } else {
            BENCH("dict_lookup_large_miss", ITERS_LARGE, {
                (void)[largeDict objectForKey:missKey];
            });
        }

        /* Benchmark 5: Large dict enumeration */
        if (json) {
            BENCH_JSON("dict_enumerate_large", 100, {
                NSEnumerator *e = [largeDict keyEnumerator];
                id key;
                while ((key = [e nextObject]) != nil) {
                    (void)[largeDict objectForKey:key];
                }
            });
        } else {
            BENCH("dict_enumerate_large", 100, {
                NSEnumerator *e = [largeDict keyEnumerator];
                id key;
                while ((key = [e nextObject]) != nil) {
                    (void)[largeDict objectForKey:key];
                }
            });
        }

        [smallDict release];
        [largeDict release];
    }

    return 0;
}
