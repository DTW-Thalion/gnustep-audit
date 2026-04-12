/*
 * test_strong_null.m - RB-4: objc_storeStrong with NULL address
 *
 * Calls objc_storeStrong() with a NULL first argument (address).
 * The fix should add a NULL check before dereferencing.
 *
 * Bug: objc_storeStrong dereferences *addr without checking if addr
 * is NULL, causing a segfault.
 *
 * Expected AFTER fix: No crash, function returns safely.
 * Expected BEFORE fix: Crash (SIGSEGV).
 */

#import <Foundation/Foundation.h>
#import <objc/objc-arc.h>
#import <objc/runtime.h>
#include <stdio.h>
#include "../../common/test_utils.h"

/* Use NSObject as root class for proper ARC support */
@interface StrongNullRoot : NSObject
@end

@implementation StrongNullRoot
@end

int main(void) {
    printf("=== RB-4: objc_storeStrong NULL Address Test ===\n\n");

    /* Test 1: objc_storeStrong with NULL address, non-nil value */
    printf("Calling objc_storeStrong(NULL, obj)...\n");
    id obj = [[StrongNullRoot alloc] init];
    objc_storeStrong(NULL, obj);
    TEST_ASSERT(1, "objc_storeStrong(NULL, obj) did not crash");

    /* Test 2: objc_storeStrong with NULL address, nil value */
    printf("Calling objc_storeStrong(NULL, nil)...\n");
    objc_storeStrong(NULL, nil);
    TEST_ASSERT(1, "objc_storeStrong(NULL, nil) did not crash");

    /* Test 3: Normal operation still works */
    id storage = nil;
    id newObj = [[StrongNullRoot alloc] init];
    objc_storeStrong(&storage, newObj);
    TEST_ASSERT(storage == newObj,
                "objc_storeStrong(&storage, newObj) stores correctly");

    /* Clear storage */
    objc_storeStrong(&storage, nil);
    TEST_ASSERT(storage == nil,
                "objc_storeStrong(&storage, nil) clears correctly");

    return TEST_SUMMARY();
}
