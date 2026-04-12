/*
 * test_cfarray_growth.m - PF-1: CFMutableArray O(n^2) growth
 *
 * CFArrayEnsureCapacity grows by a fixed +16 (DEFAULT_ARRAY_CAPACITY):
 *   newCapacity = mArray->_capacity + DEFAULT_ARRAY_CAPACITY;
 *
 * This means appending N elements requires O(N/16) reallocations,
 * each copying an increasing number of elements, resulting in O(N^2)
 * total work. A geometric growth factor (e.g., 2x) would give O(N).
 *
 * This test appends 100,000 elements and verifies it completes in
 * a reasonable time. Under O(N^2) growth the time may be noticeably
 * higher, but should still complete (just slower than necessary).
 */

#import <Foundation/Foundation.h>
#include <CoreFoundation/CFArray.h>
#include <CoreFoundation/CFNumber.h>
#include <time.h>

#include "../../common/test_utils.h"

/* Cross-platform monotonic time in seconds */
static double monotonic_seconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

int main(void)
{
    @autoreleasepool {
        printf("=== test_cfarray_growth (PF-1) ===\n");
        printf("Benchmarks appending 100000 elements to CFMutableArray.\n\n");

        CFMutableArrayRef array = CFArrayCreateMutable(
            kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
        TEST_ASSERT_NOT_NULL(array, "mutable array created");

        /* Pre-create a number to avoid measuring CFNumber allocation */
        int val = 1;
        CFNumberRef num = CFNumberCreate(kCFAllocatorDefault,
                                         kCFNumberIntType, &val);

        const int COUNT = 100000;
        double start = monotonic_seconds();

        for (int i = 0; i < COUNT; i++) {
            CFArrayAppendValue(array, num);
        }

        double elapsed = monotonic_seconds() - start;

        CFIndex finalCount = CFArrayGetCount(array);
        TEST_ASSERT_EQUAL(finalCount, (CFIndex)COUNT,
                          "array contains all appended elements");

        printf("  Appended %d elements in %.3f seconds.\n", COUNT, elapsed);

        /* With +16 linear growth and 100k elements, we get ~6250 reallocs.
         * With 2x geometric growth, we'd get ~17 reallocs.
         * Set a generous upper bound: 10 seconds should be more than enough
         * even on slow hardware. On modern hardware it should take < 1s
         * even with the O(n^2) bug. */
        TEST_ASSERT(elapsed < 10.0,
                    "append completed within 10 seconds");

        /* Warn if it looks like O(n^2) behavior (> 1 second for 100k appends
         * of a pre-allocated CFNumber suggests excessive reallocation) */
        if (elapsed > 1.0) {
            printf("  WARNING: %.3f seconds is suspiciously slow for 100k "
                   "appends.\n", elapsed);
            printf("  This may indicate O(n^2) growth (PF-1 bug).\n");
        }

        CFRelease(num);
        CFRelease(array);

        return TEST_SUMMARY();
    }
}
