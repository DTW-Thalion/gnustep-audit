/*
 * test_nscfdict_enum.m - PF-5/6: NSCFDictionary fast enumeration
 *
 * PF-5: NSCFDictionary's countByEnumeratingWithState: creates a new
 *       NSEnumerator on every call and delegates to it, but since the
 *       enumerator is freshly created each time, fast enumeration restarts
 *       from the beginning on each batch, potentially causing infinite loops
 *       or skipped/duplicated keys.
 * PF-6: The implementation also creates temporary NSArray + NSEnumerator
 *       objects on every call, causing excessive allocations.
 *
 * This test creates an NSCFDictionary (via toll-free bridge from
 * CFDictionary), enumerates it with for-in, and verifies all keys
 * are visited exactly once.
 */

#import <Foundation/Foundation.h>
#include <CoreFoundation/CFDictionary.h>
#include <CoreFoundation/CFString.h>
#include <CoreFoundation/CFNumber.h>

#include "../../common/test_utils.h"

int main(void)
{
    @autoreleasepool {
        printf("=== test_nscfdict_enum (PF-5/6) ===\n");
        printf("Validates NSCFDictionary fast enumeration visits all keys.\n\n");

        /* Create a CFDictionary with known keys */
        const int NUM_ENTRIES = 20;
        CFStringRef keys[NUM_ENTRIES];
        CFNumberRef values[NUM_ENTRIES];

        for (int i = 0; i < NUM_ENTRIES; i++) {
            char buf[32];
            snprintf(buf, sizeof(buf), "key_%03d", i);
            keys[i] = CFStringCreateWithCString(kCFAllocatorDefault, buf,
                                                 kCFStringEncodingUTF8);
            values[i] = CFNumberCreate(kCFAllocatorDefault,
                                       kCFNumberIntType, &i);
        }

        CFDictionaryRef cfDict = CFDictionaryCreate(
            kCFAllocatorDefault,
            (const void **)keys,
            (const void **)values,
            NUM_ENTRIES,
            &kCFCopyStringDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks);
        TEST_ASSERT_NOT_NULL(cfDict, "CFDictionary created");
        TEST_ASSERT_EQUAL(CFDictionaryGetCount(cfDict), (CFIndex)NUM_ENTRIES,
                          "dictionary has correct count");

        /* Toll-free bridge to NSDictionary */
        NSDictionary *nsDict = (__bridge NSDictionary *)cfDict;

        /* Use fast enumeration (for-in) */
        NSMutableSet *visitedKeys = [NSMutableSet setWithCapacity:NUM_ENTRIES];
        int iterCount = 0;
        int maxIter = NUM_ENTRIES * 3; /* safety limit to avoid infinite loop */

        for (NSString *key in nsDict) {
            iterCount++;
            [visitedKeys addObject:key];

            if (iterCount > maxIter) {
                printf("  WARNING: iteration exceeded %d, breaking "
                       "(possible infinite loop from PF-5)\n", maxIter);
                break;
            }
        }

        printf("  Expected keys: %d, Iterations: %d, Unique keys visited: %lu\n",
               NUM_ENTRIES, iterCount, (unsigned long)[visitedKeys count]);

        /* Before fix (PF-5): iterCount may be infinite or keys may be
         * duplicated because the enumerator restarts each batch.
         * After fix: iterCount == NUM_ENTRIES, all keys visited once. */
        TEST_ASSERT_EQUAL(iterCount, NUM_ENTRIES,
                          "iteration count matches entry count");
        TEST_ASSERT_EQUAL((int)[visitedKeys count], NUM_ENTRIES,
                          "all unique keys were visited exactly once");
        TEST_ASSERT(iterCount <= maxIter,
                    "enumeration terminated (no infinite loop)");

        /* Verify each expected key was visited */
        int missingKeys = 0;
        for (int i = 0; i < NUM_ENTRIES; i++) {
            NSString *expected = (__bridge NSString *)keys[i];
            if (![visitedKeys containsObject:expected]) {
                printf("  MISSING key: %s\n",
                       [expected UTF8String]);
                missingKeys++;
            }
        }
        TEST_ASSERT_EQUAL(missingKeys, 0, "no keys were missed");

        /* Cleanup */
        CFRelease(cfDict);
        for (int i = 0; i < NUM_ENTRIES; i++) {
            CFRelease(keys[i]);
            CFRelease(values[i]);
        }

        return TEST_SUMMARY();
    }
}
