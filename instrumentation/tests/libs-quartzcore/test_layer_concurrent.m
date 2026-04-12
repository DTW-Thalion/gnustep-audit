/*
 * test_layer_concurrent.m - TS-Q2: Concurrent sublayer mutation
 *
 * Modifies sublayers from one thread while iterating from another.
 *
 * Bug: CALayer's sublayers array (NSMutableArray) is not thread-safe.
 * If one thread adds/removes sublayers while another iterates the
 * sublayers array (e.g., during rendering), NSMutableArray raises a
 * "mutation during enumeration" exception or crashes from corrupted
 * internal state.
 *
 * Expected AFTER fix: No crash; mutations properly synchronized.
 * Expected BEFORE fix: Mutation-during-enumeration exception or crash.
 */

#import <Foundation/Foundation.h>
#import <QuartzCore/CALayer.h>
#include <stdio.h>
#include <pthread.h>
#include "../../common/test_utils.h"

#define NUM_ITERATIONS 500

static CALayer *sharedRoot = nil;
static volatile int mutation_errors = 0;
static volatile int stop_flag = 0;

/*
 * Thread that continuously adds and removes sublayers.
 */
static void *mutator_thread_func(void *arg) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    for (int i = 0; i < NUM_ITERATIONS && !stop_flag; i++) {
        @try {
            CALayer *layer = [CALayer layer];
            [layer setBounds: CGRectMake(0, 0, 10, 10)];
            [sharedRoot addSublayer: layer];

            /* Brief delay to increase race window */
            /* Remove the layer we just added */
            [layer removeFromSuperlayer];
        } @catch (NSException *e) {
            __sync_fetch_and_add(&mutation_errors, 1);
        }
    }

    [pool release];
    return NULL;
}

/*
 * Thread that continuously iterates sublayers.
 */
static void *iterator_thread_func(void *arg) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    for (int i = 0; i < NUM_ITERATIONS && !stop_flag; i++) {
        @try {
            NSArray *subs = [sharedRoot sublayers];
            /* Enumerate - this races with the mutator */
            NSUInteger count = 0;
            for (CALayer *sub in subs) {
                (void)[sub bounds];
                count++;
            }
            (void)count;
        } @catch (NSException *e) {
            __sync_fetch_and_add(&mutation_errors, 1);
        }
    }

    [pool release];
    return NULL;
}

int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    printf("=== TS-Q2: Concurrent Sublayer Mutation Test ===\n\n");

    /* Test 1: Single-threaded sublayer add/remove */
    printf("Testing single-threaded sublayer operations...\n");
    CALayer *root = [CALayer layer];
    for (int i = 0; i < 10; i++) {
        CALayer *sub = [CALayer layer];
        [root addSublayer: sub];
    }
    TEST_ASSERT([[root sublayers] count] == 10,
                "10 sublayers added successfully");

    for (CALayer *sub in [[root sublayers] copy]) {
        [sub removeFromSuperlayer];
    }
    TEST_ASSERT([[root sublayers] count] == 0,
                "All sublayers removed successfully");

    /* Test 2: Concurrent mutation and iteration */
    printf("\nTesting concurrent mutation (%d iterations per thread)...\n",
           NUM_ITERATIONS);

    sharedRoot = [CALayer layer];
    mutation_errors = 0;
    stop_flag = 0;

    pthread_t mutator, iterator;
    int ret;

    ret = pthread_create(&mutator, NULL, mutator_thread_func, NULL);
    TEST_ASSERT(ret == 0, "Mutator thread created");

    ret = pthread_create(&iterator, NULL, iterator_thread_func, NULL);
    TEST_ASSERT(ret == 0, "Iterator thread created");

    pthread_join(mutator, NULL);
    pthread_join(iterator, NULL);

    TEST_ASSERT(1, "Concurrent threads completed without crash");
    printf("  Mutation errors (exceptions): %d\n", mutation_errors);

    /* With the bug present, mutation_errors > 0 from
     * "mutation during enumeration" exceptions */
    TEST_ASSERT(mutation_errors == 0,
                "No mutation-during-enumeration errors");

    /* Test 3: Multiple mutators */
    printf("\nTesting multiple concurrent mutators...\n");
    sharedRoot = [CALayer layer];
    mutation_errors = 0;
    stop_flag = 0;

    pthread_t mutators[4];
    pthread_t iterators[2];

    for (int i = 0; i < 4; i++) {
        ret = pthread_create(&mutators[i], NULL, mutator_thread_func, NULL);
        TEST_ASSERT(ret == 0, "Mutator thread created");
    }
    for (int i = 0; i < 2; i++) {
        ret = pthread_create(&iterators[i], NULL, iterator_thread_func, NULL);
        TEST_ASSERT(ret == 0, "Iterator thread created");
    }

    for (int i = 0; i < 4; i++) {
        pthread_join(mutators[i], NULL);
    }
    for (int i = 0; i < 2; i++) {
        pthread_join(iterators[i], NULL);
    }

    TEST_ASSERT(1, "Multiple concurrent threads completed without crash");
    printf("  Total mutation errors: %d\n", mutation_errors);

    [pool release];
    return TEST_SUMMARY();
}
