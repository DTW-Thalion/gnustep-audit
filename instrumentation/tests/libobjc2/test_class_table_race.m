/*
 * test_class_table_race.m - TS-4: Class table concurrent access race
 *
 * Spawns threads calling objc_getClass() for known classes while the
 * main thread dynamically creates and registers new classes.
 *
 * Bug: The class table can be resized concurrently with lookups,
 * causing readers to see stale/corrupted pointers.
 *
 * Expected AFTER fix: No NULL returns for known classes, no crash.
 * Expected BEFORE fix: Crash or spurious NULL returns.
 */

#import <objc/runtime.h>
#include <stdio.h>
#include <stdatomic.h>
#include "../../common/test_utils.h"

#define NUM_READERS 4
#define LOOKUPS_PER_READER 5000
#define CLASSES_TO_CREATE 200

static atomic_int null_count = 0;
static atomic_int running = 1;

/* Well-known class names that must always be found.
 * We use the root class registered below. */
static const char *ROOT_CLASS_NAME = "ClassTableRaceRoot";

/* Minimal root class */
@interface ClassTableRaceRoot {
    Class isa;
}
@end
@implementation ClassTableRaceRoot
@end

static void *reader_thread(void *arg) {
    (void)arg;
    int local_nulls = 0;

    for (int i = 0; i < LOOKUPS_PER_READER; i++) {
        Class cls = objc_getClass(ROOT_CLASS_NAME);
        if (!cls) {
            local_nulls++;
        }
    }

    atomic_fetch_add(&null_count, local_nulls);
    return NULL;
}

int main(void) {
    printf("=== TS-4: Class Table Race Condition Test ===\n\n");

    /* Verify our root class is reachable first */
    Class root = objc_getClass(ROOT_CLASS_NAME);
    TEST_ASSERT_NOT_NULL(root, "root class is registered");

    /* Start reader threads */
    pthread_t readers[NUM_READERS];
    for (int i = 0; i < NUM_READERS; i++) {
        pthread_create(&readers[i], NULL, reader_thread, NULL);
    }

    /* Main thread creates dynamic classes to force table mutations */
    char namebuf[64];
    for (int i = 0; i < CLASSES_TO_CREATE; i++) {
        snprintf(namebuf, sizeof(namebuf), "DynClassRace_%d", i);
        Class newCls = objc_allocateClassPair(root, namebuf, 0);
        if (newCls) {
            objc_registerClassPair(newCls);
        }
    }

    /* Wait for readers */
    for (int i = 0; i < NUM_READERS; i++) {
        pthread_join(readers[i], NULL);
    }

    int nulls = atomic_load(&null_count);
    TEST_ASSERT_EQUAL(nulls, 0,
                      "no NULL returns for known class during concurrent mutations");

    printf("Performed %d lookups across %d threads with %d dynamic class registrations.\n",
           NUM_READERS * LOOKUPS_PER_READER, NUM_READERS, CLASSES_TO_CREATE);

    /* Verify dynamic classes exist */
    int found = 0;
    for (int i = 0; i < CLASSES_TO_CREATE; i++) {
        snprintf(namebuf, sizeof(namebuf), "DynClassRace_%d", i);
        if (objc_getClass(namebuf)) {
            found++;
        }
    }
    TEST_ASSERT_EQUAL(found, CLASSES_TO_CREATE,
                      "all dynamically created classes are findable");

    return TEST_SUMMARY();
}
