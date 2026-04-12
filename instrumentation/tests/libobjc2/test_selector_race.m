/*
 * test_selector_race.m - TS-2/TS-3: Selector registration data races
 *
 * Spawns 8 threads each registering 1000 unique selectors concurrently
 * via sel_registerName().  Verifies no crash and all selectors are
 * retrievable afterward.
 *
 * Bug: The selector table uses a non-thread-safe hash map.  Concurrent
 * insertions can corrupt the table, leading to crashes or lost selectors.
 *
 * Expected AFTER fix: All 8000 selectors registered and retrievable.
 * Expected BEFORE fix: Crash, hang, or missing selectors.
 */

#import <objc/runtime.h>
#include <stdio.h>
#include <string.h>
#include "../../common/test_utils.h"

#define NUM_THREADS 8
#define SELS_PER_THREAD 1000

/* Each thread gets a unique prefix to avoid collisions */
static void *register_selectors(void *arg) {
    int tid = (int)(intptr_t)arg;
    char buf[64];

    for (int i = 0; i < SELS_PER_THREAD; i++) {
        snprintf(buf, sizeof(buf), "selRaceTest_t%d_s%d:", tid, i);
        SEL s = sel_registerName(buf);
        if (!s) {
            printf("FAIL: sel_registerName returned NULL for %s\n", buf);
        }
    }
    return NULL;
}

int main(void) {
    printf("=== TS-2/TS-3: Selector Registration Race Test ===\n\n");

    /* Spawn threads */
    pthread_t threads[NUM_THREADS];
    for (int i = 0; i < NUM_THREADS; i++) {
        pthread_create(&threads[i], NULL, register_selectors,
                       (void *)(intptr_t)i);
    }
    for (int i = 0; i < NUM_THREADS; i++) {
        pthread_join(threads[i], NULL);
    }

    TEST_ASSERT(1, "all threads completed without crash");

    /* Verify all selectors are retrievable */
    int missing = 0;
    char buf[64];
    for (int t = 0; t < NUM_THREADS; t++) {
        for (int s = 0; s < SELS_PER_THREAD; s++) {
            snprintf(buf, sizeof(buf), "selRaceTest_t%d_s%d:", t, s);
            SEL sel = sel_registerName(buf);
            const char *name = sel_getName(sel);
            if (!name || strcmp(name, buf) != 0) {
                missing++;
                if (missing <= 5) {
                    printf("  missing/corrupt: %s\n", buf);
                }
            }
        }
    }

    TEST_ASSERT_EQUAL(missing, 0,
                      "all registered selectors are retrievable with correct names");

    printf("Registered and verified %d selectors across %d threads.\n",
           NUM_THREADS * SELS_PER_THREAD, NUM_THREADS);

    return TEST_SUMMARY();
}
