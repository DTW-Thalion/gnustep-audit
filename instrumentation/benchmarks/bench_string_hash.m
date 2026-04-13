/*
 * bench_string_hash.m - String hash computation benchmark
 *
 * Measures hash computation throughput for short / medium / long strings,
 * and explicitly separates tagged-pointer (GSTinyString) from heap-backed
 * NSString representations so the tiny-string fast path is visible in the
 * comparison output.
 *
 * Targets: hash optimization + B2 tagged-pointer audit (expose tiny path).
 *
 * The hash_tiny_* / hash_heap_* variants were added as part of the B2
 * follow-up (docs/spikes/2026-04-13-tagged-pointer-nsstring.md §6.3)
 * so that a future regression in GSTinyString -hash is immediately
 * visible and distinguishable from a regression in the general
 * GSString -hash path.
 *
 * Usage: ./bench_string_hash [--json]
 */

#import <Foundation/Foundation.h>
#include <stdint.h>
#include "bench_harness.h"

#define ITERATIONS 5000000

/* A nonzero low-3-bits tag on the pointer means it's a small (tagged)
 * object. GSTinyString registers at TINY_STRING_MASK == 4 on libobjc2
 * (GSString.m:1122), but any nonzero tag means "not heap."
 * Silence the clang "bitmasking for introspection" warning — our use
 * is deliberate tagged-pointer detection. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-objc-pointer-introspection"
static BOOL is_tagged(id obj) {
    return obj != nil && ((uintptr_t)obj & 7u) != 0;
}
#pragma clang diagnostic pop

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

/* Guaranteed heap-backed (never tagged): go through NSMutableString and
 * then copy. GNUstep's -[NSMutableString copy] returns a concrete
 * GSCInlineString / GSCString — not a tagged pointer — preserving the
 * layout across the immutable transition. */
static NSString *makeHeapString(int length) {
    NSMutableString *m = [NSMutableString stringWithCapacity:(NSUInteger)length + 1];
    for (int i = 0; i < length; i++) {
        [m appendFormat:@"%c", (char)('a' + (i % 26))];
    }
    return [[m copy] autorelease];
}

int main(int argc, char *argv[]) {
    int json = (argc > 1 && strcmp(argv[1], "--json") == 0);

    @autoreleasepool {
        NSString *shortStr  = makeString(5);
        NSString *medStr    = makeString(50);
        NSString *longStr   = makeString(500);

        /* Explicit tagged-pointer (tiny) vs heap variants for B2 coverage.
         * tinyStr: 5-char ASCII via +stringWithCString:encoding: — should be
         *   tagged on libobjc2 (OBJC_SMALL_OBJECT_SHIFT == 3) builds.
         * heapShortStr: same 5-char content via NSMutableString -copy —
         *   guaranteed heap-backed even on libobjc2.
         * If tinyStr is NOT tagged at runtime (a non-libobjc2 build), the
         * hash_tiny_5 result is still valid and simply reflects the
         * fallback heap path, which is what the comparison would measure
         * on that build anyway. */
        NSString *tinyStr     = [NSString stringWithCString:"abcde"
                                                   encoding:NSASCIIStringEncoding];
        NSString *heapShortStr = makeHeapString(5);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-objc-pointer-introspection"
        if (json) {
            printf("{\"bench\":\"_meta\",\"tiny_active\":%s,"
                   "\"tiny_ptr_tag\":%lu}\n",
                   is_tagged(tinyStr) ? "true" : "false",
                   (unsigned long)((uintptr_t)tinyStr & 7u));
        }
#pragma clang diagnostic pop

        /* Benchmark 1: Short string hash (5 chars) — historical alias,
         * may or may not be tagged depending on the init path the
         * runtime chooses for makeString(5). */
        if (json) {
            BENCH_JSON("hash_short_5", ITERATIONS, {
                (void)[shortStr hash];
            });
        } else {
            BENCH("hash_short_5", ITERATIONS, {
                (void)[shortStr hash];
            });
        }

        /* Benchmark 1a: Tagged-pointer tiny string hash (5 chars, ASCII).
         * Isolates the GSTinyString -hash fast path from the general
         * NSString -hash path. On libobjc2 this measures the unichar-
         * widening + GSPrivateHash fast-path at GSString.m:1001-1033. */
        if (json) {
            BENCH_JSON("hash_tiny_5", ITERATIONS, {
                (void)[tinyStr hash];
            });
        } else {
            BENCH("hash_tiny_5", ITERATIONS, {
                (void)[tinyStr hash];
            });
        }

        /* Benchmark 1b: Heap-backed short string hash (5 chars).
         * Paired with hash_tiny_5: same content, forced heap layout.
         * A non-trivial delta between hash_tiny_5 and hash_heap_5
         * quantifies the tagged-pointer hash win. */
        if (json) {
            BENCH_JSON("hash_heap_5", ITERATIONS, {
                (void)[heapShortStr hash];
            });
        } else {
            BENCH("hash_heap_5", ITERATIONS, {
                (void)[heapShortStr hash];
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
        /* tinyStr and heapShortStr are autoreleased via the factories
         * used to build them, so no explicit release here. */
    }

    return 0;
}
