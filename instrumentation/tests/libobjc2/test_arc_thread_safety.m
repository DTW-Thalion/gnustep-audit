/*
 * test_arc_thread_safety.m - TS-12/TS-14: Autorelease pool thread safety
 *
 * Tests concurrent autorelease pool creation and draining from multiple
 * threads.  Each thread creates and drains pools 1000 times.
 *
 * Bug: The autorelease pool stack uses thread-local storage that may
 * not be properly initialized on all threads, or concurrent pushes/pops
 * on fast paths may corrupt the TLS state.
 *
 * Expected AFTER fix: All threads complete without crash.
 * Expected BEFORE fix: Crash (double-free, segfault in pool drain).
 */

#import <objc/objc-arc.h>
#import <objc/runtime.h>
#include <stdio.h>
#include "../../common/test_utils.h"

#define POOL_ITERATIONS 1000

/* Minimal root class with basic retain/release */
@interface ARCTestRoot {
    Class isa;
}
+ (id)alloc;
- (id)init;
@end

@implementation ARCTestRoot
+ (id)alloc {
    return class_createInstance(self, 0);
}
- (id)init {
    return self;
}
@end

static void *pool_stress(void *arg) {
    (void)arg;
    for (int i = 0; i < POOL_ITERATIONS; i++) {
        void *pool = objc_autoreleasePoolPush();
        /* Create a few objects in the pool */
        for (int j = 0; j < 5; j++) {
            id obj = [[ARCTestRoot alloc] init];
            objc_autorelease(obj);
        }
        objc_autoreleasePoolPop(pool);
    }
    return NULL;
}

int main(void) {
    printf("=== TS-12/TS-14: ARC Autorelease Pool Thread Safety Test ===\n\n");

    /* Test 1: Single-thread sanity check */
    void *pool = objc_autoreleasePoolPush();
    id obj = [[ARCTestRoot alloc] init];
    objc_autorelease(obj);
    objc_autoreleasePoolPop(pool);
    TEST_ASSERT(1, "single-thread pool push/pop works");

    /* Test 2: Multi-thread stress */
    int rc = run_stress_threads(8, pool_stress, NULL);
    TEST_ASSERT_EQUAL(rc, 0, "all 8 pool-stress threads completed");
    TEST_ASSERT(1, "no crash during concurrent autorelease pool operations");

    printf("Each of 8 threads pushed/popped %d autorelease pools.\n",
           POOL_ITERATIONS);

    return TEST_SUMMARY();
}
