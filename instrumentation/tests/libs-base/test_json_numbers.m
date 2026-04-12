/*
 * test_json_numbers.m - RB-13: JSON number precision loss
 *
 * Parse JSON with very large numbers and integers. Verify no silent
 * precision loss for integers that fit in long long.
 */
#import <Foundation/Foundation.h>
#include "../../common/test_utils.h"
#include <limits.h>

static BOOL parseAndCheckInteger(NSString *json, long long expected, const char *desc) {
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;
    id result = [NSJSONSerialization JSONObjectWithData:data
                                               options:0
                                                 error:&error];
    if (result == nil) {
        printf("  Parse failed for %s: %s\n", desc,
               [[error localizedDescription] UTF8String]);
        return NO;
    }

    /* Result should be an array with one number */
    if (![result isKindOfClass:[NSArray class]] || [result count] < 1) {
        printf("  Unexpected result type for %s\n", desc);
        return NO;
    }

    NSNumber *num = [result objectAtIndex:0];
    long long actual = [num longLongValue];

    if (actual != expected) {
        printf("  PRECISION LOSS for %s:\n", desc);
        printf("    Expected: %lld\n", expected);
        printf("    Got:      %lld\n", actual);
        printf("    NSNumber: %s (objCType: %s)\n",
               [[num description] UTF8String], [num objCType]);
        return NO;
    }

    return YES;
}

int main(void) {
    @autoreleasepool {
        printf("=== test_json_numbers (RB-13) ===\n");

        /* Test 1: Simple integers */
        BOOL ok;
        ok = parseAndCheckInteger(@"[42]", 42, "simple integer 42");
        TEST_ASSERT(ok, "Parse integer 42 correctly");

        ok = parseAndCheckInteger(@"[0]", 0, "zero");
        TEST_ASSERT(ok, "Parse integer 0 correctly");

        ok = parseAndCheckInteger(@"[-1]", -1, "negative one");
        TEST_ASSERT(ok, "Parse integer -1 correctly");

        /* Test 2: Large integers that fit in long long (53-bit+) */
        /* 2^53 = 9007199254740992 (max exact double) */
        ok = parseAndCheckInteger(@"[9007199254740992]",
                                  9007199254740992LL,
                                  "2^53 (max exact double)");
        TEST_ASSERT(ok, "Parse 2^53 without precision loss");

        /* 2^53 + 1 = 9007199254740993 (cannot be exact in double) */
        ok = parseAndCheckInteger(@"[9007199254740993]",
                                  9007199254740993LL,
                                  "2^53+1 (beyond double precision)");
        if (ok) {
            printf("  2^53+1 preserved correctly (integer path used).\n");
        } else {
            printf("  2^53+1 lost precision (converted through double).\n");
        }
        TEST_ASSERT(ok, "Parse 2^53+1 without precision loss");

        /* Test 3: LLONG_MAX = 9223372036854775807 */
        ok = parseAndCheckInteger(@"[9223372036854775807]",
                                  LLONG_MAX,
                                  "LLONG_MAX");
        if (ok) {
            printf("  LLONG_MAX preserved correctly.\n");
        } else {
            printf("  LLONG_MAX lost precision.\n");
        }
        TEST_ASSERT(ok, "Parse LLONG_MAX without precision loss");

        /* Test 4: LLONG_MIN = -9223372036854775808 */
        ok = parseAndCheckInteger(@"[-9223372036854775808]",
                                  LLONG_MIN,
                                  "LLONG_MIN");
        if (ok) {
            printf("  LLONG_MIN preserved correctly.\n");
        } else {
            printf("  LLONG_MIN lost precision.\n");
        }
        TEST_ASSERT(ok, "Parse LLONG_MIN without precision loss");

        /* Test 5: Large integer commonly seen in APIs (Twitter snowflake IDs) */
        ok = parseAndCheckInteger(@"[1352735648926101504]",
                                  1352735648926101504LL,
                                  "snowflake-like ID");
        TEST_ASSERT(ok, "Parse large snowflake-like ID correctly");

        /* Test 6: Floating point numbers should be OK */
        {
            NSData *data = [@"[3.14159]" dataUsingEncoding:NSUTF8StringEncoding];
            NSError *error = nil;
            NSArray *result = [NSJSONSerialization JSONObjectWithData:data
                                                             options:0
                                                               error:&error];
            TEST_ASSERT(result != nil, "Parse floating point number");
            if (result && [result count] > 0) {
                double val = [[result objectAtIndex:0] doubleValue];
                double diff = val - 3.14159;
                if (diff < 0) diff = -diff;
                TEST_ASSERT(diff < 0.00001,
                            "Floating point value should be close to 3.14159");
            }
        }

        /* Test 7: Number at boundary between int and long long */
        ok = parseAndCheckInteger(@"[2147483648]",
                                  2147483648LL,
                                  "INT_MAX+1 (2^31)");
        TEST_ASSERT(ok, "Parse INT_MAX+1 correctly (must use long long)");

        ok = parseAndCheckInteger(@"[-2147483649]",
                                  -2147483649LL,
                                  "INT_MIN-1");
        TEST_ASSERT(ok, "Parse INT_MIN-1 correctly (must use long long)");

        return TEST_SUMMARY();
    }
}
