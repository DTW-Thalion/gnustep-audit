/*
 * test_cfplist_deepcopy.m - BUG-7: CFPropertyListCreateDeepCopy returns empty
 *
 * When opts != kCFPropertyListImmutable (i.e., mutable deep copy),
 * CFPropertyListCreateDeepCopy creates a mutable array, then calls
 * CFArrayApplyFunction on the NEW (empty) array instead of the SOURCE array:
 *
 *   array = CFArrayCreateMutable(alloc, cnt, ...);
 *   CFArrayApplyFunction(array, range, ...);  // BUG: should be (plist, range, ...)
 *
 * The empty array has zero elements, so the apply function iterates nothing,
 * and the copy comes back empty.
 *
 * This test creates a mutable deep copy and verifies it has the same values.
 */

#import <Foundation/Foundation.h>
#include <CoreFoundation/CFPropertyList.h>
#include <CoreFoundation/CFArray.h>
#include <CoreFoundation/CFString.h>
#include <CoreFoundation/CFNumber.h>

#include "../../common/test_utils.h"

int main(void)
{
    @autoreleasepool {
        printf("=== test_cfplist_deepcopy (BUG-7) ===\n");
        printf("Validates mutable deep copy preserves array contents.\n\n");

        /* Create a source array with a few values */
        CFStringRef str1 = CFSTR("hello");
        CFStringRef str2 = CFSTR("world");
        int intVal = 42;
        CFNumberRef num = CFNumberCreate(kCFAllocatorDefault,
                                         kCFNumberIntType, &intVal);

        const void *values[] = { str1, str2, num };
        CFArrayRef source = CFArrayCreate(kCFAllocatorDefault, values, 3,
                                          &kCFTypeArrayCallBacks);
        TEST_ASSERT_NOT_NULL(source, "source array created");
        TEST_ASSERT_EQUAL(CFArrayGetCount(source), 3,
                          "source array has 3 elements");

        /* Mutable deep copy — this is the buggy path */
        CFPropertyListRef copy = CFPropertyListCreateDeepCopy(
            kCFAllocatorDefault,
            source,
            kCFPropertyListMutableContainersAndLeaves);

        TEST_ASSERT_NOT_NULL(copy, "deep copy is non-NULL");

        CFIndex copyCount = CFArrayGetCount((CFArrayRef)copy);
        printf("  Source count: %ld, Copy count: %ld\n",
               (long)CFArrayGetCount(source), (long)copyCount);

        /* Before fix: copyCount == 0 (apply function ran on empty array)
         * After fix:  copyCount == 3 */
        TEST_ASSERT_EQUAL(copyCount, 3,
                          "deep copy has same number of elements");

        if (copyCount == 3) {
            /* Verify values match */
            CFStringRef c1 = (CFStringRef)CFArrayGetValueAtIndex(
                (CFArrayRef)copy, 0);
            CFStringRef c2 = (CFStringRef)CFArrayGetValueAtIndex(
                (CFArrayRef)copy, 1);
            CFNumberRef c3 = (CFNumberRef)CFArrayGetValueAtIndex(
                (CFArrayRef)copy, 2);

            TEST_ASSERT(CFStringCompare(c1, str1, 0) == kCFCompareEqualTo,
                        "first element matches");
            TEST_ASSERT(CFStringCompare(c2, str2, 0) == kCFCompareEqualTo,
                        "second element matches");
            TEST_ASSERT(CFEqual(c3, num),
                        "third element matches");

            /* Verify it's actually a deep copy (different pointers) */
            TEST_ASSERT(c1 != str1 || c2 != str2,
                        "deep copy created new objects (not shallow)");
        }

        /* Cleanup */
        if (copy) CFRelease(copy);
        CFRelease(source);
        CFRelease(num);

        return TEST_SUMMARY();
    }
}
