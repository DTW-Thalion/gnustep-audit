/*
 * test_transaction_thread.m - TS-Q1: CATransaction thread safety
 *
 * Calls [CATransaction begin]/[CATransaction commit] from multiple
 * threads simultaneously.
 *
 * Bug: CATransaction uses a global static NSMutableArray (transactionStack)
 * with no locking. Concurrent access from multiple threads causes the
 * array to be corrupted (duplicate adds, missing removes, or crashes
 * from mutating during enumeration).
 *
 * Expected AFTER fix: No crash; transactions properly isolated per-thread
 * or properly locked.
 * Expected BEFORE fix: Corrupts global stack; likely crash or assertion.
 */

#import <Foundation/Foundation.h>
#import <QuartzCore/CATransaction.h>
#include <stdio.h>
#include <pthread.h>
#include "../../common/test_utils.h"

#define NUM_THREADS 8
#define ITERATIONS_PER_THREAD 100

static volatile int thread_errors = 0;

static void *transaction_thread_func(void *arg) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    int tid = *(int *)arg;

    for (int i = 0; i < ITERATIONS_PER_THREAD; i++) {
        @try {
            [CATransaction begin];
            [CATransaction setAnimationDuration: 0.25];

            /* Simulate some work between begin/commit */
            /* Nested transaction */
            [CATransaction begin];
            [CATransaction setDisableActions: YES];
            [CATransaction commit];

            [CATransaction commit];
        } @catch (NSException *e) {
            __sync_fetch_and_add(&thread_errors, 1);
            if (i == 0) {
                printf("  Thread %d exception: %s\n",
                       tid, [[e reason] UTF8String]);
            }
        }
    }

    [pool release];
    return NULL;
}

int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    printf("=== TS-Q1: CATransaction Thread Safety Test ===\n\n");

    /* Test 1: Basic single-threaded begin/commit works */
    printf("Testing single-threaded begin/commit...\n");
    [CATransaction begin];
    [CATransaction commit];
    TEST_ASSERT(1, "Single-threaded begin/commit succeeded");

    /* Test 2: Nested transactions on single thread */
    printf("Testing nested transactions...\n");
    [CATransaction begin];
    [CATransaction begin];
    [CATransaction commit];
    [CATransaction commit];
    TEST_ASSERT(1, "Nested transactions succeeded");

    /* Test 3: Multi-threaded concurrent begin/commit */
    printf("Testing %d threads x %d iterations of begin/commit...\n",
           NUM_THREADS, ITERATIONS_PER_THREAD);

    pthread_t threads[NUM_THREADS];
    int tids[NUM_THREADS];

    for (int i = 0; i < NUM_THREADS; i++) {
        tids[i] = i;
        int ret = pthread_create(&threads[i], NULL, transaction_thread_func, &tids[i]);
        TEST_ASSERT(ret == 0, "Thread creation succeeded");
    }

    for (int i = 0; i < NUM_THREADS; i++) {
        pthread_join(threads[i], NULL);
    }

    TEST_ASSERT(1, "All transaction threads completed without crash");
    printf("  Thread errors: %d\n", thread_errors);
    TEST_ASSERT(thread_errors == 0,
                "No exceptions during concurrent transactions");

    /* Test 4: Verify transactions still work after stress test */
    printf("Verifying transactions work after stress test...\n");
    @try {
        [CATransaction begin];
        [CATransaction setAnimationDuration: 1.0];
        [CATransaction commit];
        TEST_ASSERT(1, "Post-stress transaction succeeded");
    } @catch (NSException *e) {
        TEST_ASSERT(0, "Post-stress transaction threw exception");
    }

    [pool release];
    return TEST_SUMMARY();
}
