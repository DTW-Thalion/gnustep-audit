/*
 * test_pool_thread.m - TS-1: NSAutoreleasePool cross-thread drain
 *
 * Create an NSAutoreleasePool on thread A. Try to drain/release it from
 * thread B. After fix: assertion or exception. Before fix: corrupts thread
 * B's pool chain.
 */
#import <Foundation/Foundation.h>
#include "../../common/test_utils.h"
#include <pthread.h>

static NSAutoreleasePool *sharedPool = nil;
static volatile int drainResult = 0; /* 0=not run, 1=exception, 2=no exception */

static void *drainFromOtherThread(void *arg) {
    (void)arg;

    @autoreleasepool {
        /*
         * Try to drain a pool created on the main thread.
         * This is undefined behavior / a programming error.
         * A proper implementation should raise an exception or assert.
         */
        @try {
            [sharedPool drain];
            drainResult = 2; /* No exception - bad */
        } @catch (NSException *e) {
            printf("  Exception caught: %s - %s\n",
                   [[e name] UTF8String], [[e reason] UTF8String]);
            drainResult = 1; /* Exception - good */
        }
    }

    return NULL;
}

int main(void) {
    @autoreleasepool {
        printf("=== test_pool_thread (TS-1) ===\n");

        /*
         * Create a nested pool on the main thread.
         * Note: We use the explicit alloc/init rather than @autoreleasepool
         * so we can hand the reference to another thread.
         */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        sharedPool = [[NSAutoreleasePool alloc] init];
#pragma clang diagnostic pop

        TEST_ASSERT_NOT_NULL(sharedPool, "Pool created on main thread");

        /* Spawn thread B to try draining our pool */
        pthread_t thread;
        int rc = pthread_create(&thread, NULL, drainFromOtherThread, NULL);
        TEST_ASSERT(rc == 0, "Thread B created successfully");

        if (rc == 0) {
            pthread_join(thread, NULL);

            /*
             * After fix: drainResult should be 1 (exception caught).
             * Before fix: drainResult is 2 (no exception, pool chain corrupted).
             */
            if (drainResult == 1) {
                printf("  Cross-thread pool drain correctly rejected.\n");
                TEST_ASSERT(1, "Cross-thread drain raised exception (correct)");
            } else if (drainResult == 2) {
                printf("  WARNING: Cross-thread pool drain succeeded!\n");
                printf("  This can corrupt the autorelease pool chain.\n");
                /*
                 * We record this as a test assertion. Before fix, this is the
                 * expected (buggy) behavior.
                 */
                TEST_ASSERT(0, "Cross-thread drain should raise exception");
            } else {
                printf("  Drain was not executed (unexpected).\n");
                TEST_ASSERT(0, "Drain should have been attempted");
            }
        }

        /*
         * If the pool was drained by the other thread, we must not drain
         * it again. If it wasn't drained, we need to release it.
         */
        if (drainResult != 2) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [sharedPool release];
#pragma clang diagnostic pop
        }

        /*
         * Verify main thread's pool chain is intact by creating and
         * draining another pool.
         */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSAutoreleasePool *verifyPool = [[NSAutoreleasePool alloc] init];
        NSString *s = [[[NSString alloc] initWithFormat:@"test %d", 42] autorelease];
        TEST_ASSERT_NOT_NULL(s, "Autorelease works after cross-thread test");
        [verifyPool drain];
#pragma clang diagnostic pop

        TEST_ASSERT(1, "Main thread pool chain intact after test");

        return TEST_SUMMARY();
    }
}
