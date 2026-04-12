/*
 * test_zone_oom.m - RB-3: Zone mutex released on OOM
 *
 * Test that the zone mutex is properly released when allocation fails.
 * Hard to trigger real OOM, so we verify the zone remains usable after
 * a failed allocation attempt (requesting an absurdly large size).
 */
#import <Foundation/Foundation.h>
#include "../../common/test_utils.h"
#include <pthread.h>

static NSZone *testZone = NULL;
static volatile int threadSuccess = 0;

static void *allocFromZone(void *arg) {
    (void)arg;

    @autoreleasepool {
        /*
         * Try to allocate from the zone after the main thread's huge
         * allocation failed. If the zone mutex was not released on OOM,
         * this will deadlock.
         */
        void *ptr = NSZoneMalloc(testZone, 64);
        if (ptr != NULL) {
            threadSuccess = 1;
            NSZoneFree(testZone, ptr);
        }
    }

    return NULL;
}

int main(void) {
    @autoreleasepool {
        printf("=== test_zone_oom (RB-3) ===\n");

        /* Create a custom zone for testing */
        testZone = NSCreateZone(4096, 4096, YES);
        TEST_ASSERT_NOT_NULL(testZone, "Custom zone created");

        if (testZone == NULL) {
            printf("  Cannot create zone, skipping test.\n");
            return TEST_SUMMARY();
        }

        /* Verify basic allocation works */
        void *p1 = NSZoneMalloc(testZone, 128);
        TEST_ASSERT_NOT_NULL(p1, "Normal allocation from zone should work");
        if (p1) NSZoneFree(testZone, p1);

        /*
         * Attempt an absurdly large allocation that should fail.
         * We request SIZE_MAX / 2 which cannot possibly succeed.
         */
        size_t hugeSize = (size_t)-1 / 2;
        void *huge = NULL;

        @try {
            huge = NSZoneMalloc(testZone, hugeSize);
        } @catch (NSException *e) {
            printf("  Exception on huge alloc: %s\n",
                   [[e reason] UTF8String]);
            huge = NULL;
        }

        if (huge != NULL) {
            printf("  WARNING: Huge allocation unexpectedly succeeded!\n");
            NSZoneFree(testZone, huge);
        } else {
            printf("  Huge allocation correctly failed.\n");
        }

        /*
         * Now verify the zone is still usable (mutex was released).
         * Try allocation from another thread - if mutex is stuck,
         * this will deadlock.
         */
        pthread_t thread;
        int rc = pthread_create(&thread, NULL, allocFromZone, NULL);
        TEST_ASSERT(rc == 0, "Thread created to test zone after OOM");

        if (rc == 0) {
            /*
             * Join the thread. If the zone mutex is stuck, this will
             * deadlock -- the outer test harness timeout will catch that.
             * pthread_timedjoin_np is not portable (Linux glibc only),
             * so we use a plain join here.
             */
            pthread_join(thread, NULL);
            TEST_ASSERT(threadSuccess == 1,
                        "Thread successfully allocated from zone after OOM");
            if (threadSuccess) {
                printf("  Zone remains usable after failed allocation.\n");
            }
        }

        /* Additional: verify zone still works from main thread */
        void *p2 = NSZoneMalloc(testZone, 256);
        TEST_ASSERT_NOT_NULL(p2, "Zone usable from main thread after OOM test");
        if (p2) NSZoneFree(testZone, p2);

        /* Clean up */
        NSRecycleZone(testZone);

        return TEST_SUMMARY();
    }
}
