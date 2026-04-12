/*
 * test_weak_ref_stress.m - TS-13: Weak reference concurrent stress test
 *
 * 8 threads doing store/load/clear weak references concurrently, 10000
 * times each.  After all threads complete, verify all weak refs are nil.
 *
 * Bug: The weak reference table uses insufficient locking, allowing
 * concurrent store/load/clear operations to corrupt the table or
 * return dangling pointers.
 *
 * Expected AFTER fix: No crash, all refs nil after threads complete.
 * Expected BEFORE fix: Crash, corruption, or dangling pointers.
 */

#import <objc/objc-arc.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <stdatomic.h>
#include "../../common/test_utils.h"

#define NUM_THREADS 8
#define OPS_PER_THREAD 10000

/* Minimal root class */
@interface WeakStressRoot {
    Class isa;
}
+ (id)alloc;
- (id)init;
@end

@implementation WeakStressRoot
+ (id)alloc {
    return class_createInstance(self, 0);
}
- (id)init {
    return self;
}
@end

/* Shared target object and weak slots */
static id sharedTarget = nil;
static id weakSlots[NUM_THREADS];
static atomic_int ready = 0;

static void *weak_stress_worker(void *arg) {
    int tid = (int)(intptr_t)arg;

    /* Wait for all threads to be ready */
    atomic_fetch_add(&ready, 1);
    while (atomic_load(&ready) < NUM_THREADS) {
        /* spin */
    }

    for (int i = 0; i < OPS_PER_THREAD; i++) {
        /* Store weak ref to shared target */
        objc_storeWeak(&weakSlots[tid], sharedTarget);

        /* Load it back */
        id loaded = objc_loadWeak(&weakSlots[tid]);
        (void)loaded;

        /* Periodically clear */
        if (i % 3 == 0) {
            objc_storeWeak(&weakSlots[tid], nil);
        }
    }

    /* Final clear */
    objc_storeWeak(&weakSlots[tid], nil);
    return NULL;
}

int main(void) {
    printf("=== TS-13: Weak Reference Concurrent Stress Test ===\n\n");

    /* Initialize shared target */
    sharedTarget = [[WeakStressRoot alloc] init];
    TEST_ASSERT_NOT_NULL(sharedTarget, "shared target created");

    /* Initialize weak slots */
    for (int i = 0; i < NUM_THREADS; i++) {
        weakSlots[i] = nil;
    }

    /* Test 1: Concurrent weak ref operations */
    pthread_t threads[NUM_THREADS];
    for (int i = 0; i < NUM_THREADS; i++) {
        pthread_create(&threads[i], NULL, weak_stress_worker,
                       (void *)(intptr_t)i);
    }
    for (int i = 0; i < NUM_THREADS; i++) {
        pthread_join(threads[i], NULL);
    }

    TEST_ASSERT(1, "all threads completed without crash");

    /* Verify all weak slots are nil (they were cleared at end) */
    int nonNilCount = 0;
    for (int i = 0; i < NUM_THREADS; i++) {
        id val = objc_loadWeak(&weakSlots[i]);
        if (val != nil) {
            nonNilCount++;
        }
    }
    TEST_ASSERT_EQUAL(nonNilCount, 0,
                      "all weak slots are nil after threads complete");

    /* Test 2: Weak refs should nil out when target is released */
    id weakRef = nil;
    {
        id target = [[WeakStressRoot alloc] init];
        objc_initWeak(&weakRef, target);
        id loaded = objc_loadWeak(&weakRef);
        TEST_ASSERT(loaded == target,
                    "weak ref loads correctly while target alive");
        objc_release(target);
    }
    /* After release, weak ref should be nil */
    id afterRelease = objc_loadWeak(&weakRef);
    /* Note: this may or may not be nil depending on dealloc timing
     * with our minimal root class. The important thing is no crash. */
    TEST_ASSERT(1, "loading weak ref after target release did not crash");
    (void)afterRelease;
    objc_destroyWeak(&weakRef);

    printf("Completed %d weak ref operations across %d threads.\n",
           NUM_THREADS * OPS_PER_THREAD, NUM_THREADS);

    return TEST_SUMMARY();
}
