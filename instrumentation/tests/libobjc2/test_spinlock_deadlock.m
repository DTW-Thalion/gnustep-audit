/*
 * test_spinlock_deadlock.m - TS-7: Atomic property copy spinlock deadlock
 *
 * Validates that rapidly copying between two atomic properties on the
 * same object does not deadlock.
 *
 * Bug: The runtime uses a spinlock per property slot, and copying between
 * two properties on the same object can acquire locks in inconsistent
 * order, leading to deadlock.
 *
 * Uses alarm() as a 2-second watchdog -- if we deadlock, SIGALRM kills us.
 *
 * Expected AFTER fix: Completes within the watchdog timeout.
 * Expected BEFORE fix: Hangs, killed by SIGALRM (exit code non-zero).
 */

#import <Foundation/Foundation.h>
#include <signal.h>
#include <pthread.h>
#include "../../common/test_utils.h"

/* Platform-specific watchdog */
#ifdef _WIN32
#include <windows.h>
static DWORD WINAPI watchdog_thread(LPVOID arg) {
    Sleep(4000);  /* 4 seconds */
    fprintf(stderr, "\nFAIL: Watchdog timeout -- probable deadlock!\n");
    fflush(stderr);
    _exit(1);
    return 0;
}
static void start_watchdog(void) {
    CreateThread(NULL, 0, watchdog_thread, NULL, 0, NULL);
}
#else
static void alarm_handler(int sig) {
    (void)sig;
    fprintf(stderr, "\nFAIL: Watchdog timeout (SIGALRM) -- probable deadlock!\n");
    fflush(stderr);
    _exit(1);
}
static void start_watchdog(void) {
    signal(SIGALRM, alarm_handler);
    alarm(4);
}
#endif

@interface AtomicPropObj : NSObject
@property (atomic, copy) NSString *propA;
@property (atomic, copy) NSString *propB;
@end

@implementation AtomicPropObj
@end

static AtomicPropObj *sharedObj;
static const int ITERATIONS = 10000;

static void *copy_a_to_b(void *arg) {
    (void)arg;
    for (int i = 0; i < ITERATIONS; i++) {
        sharedObj.propB = sharedObj.propA;
    }
    return NULL;
}

static void *copy_b_to_a(void *arg) {
    (void)arg;
    for (int i = 0; i < ITERATIONS; i++) {
        sharedObj.propA = sharedObj.propB;
    }
    return NULL;
}

int main(void) {
    @autoreleasepool {
        printf("=== TS-7: Atomic Property Spinlock Deadlock Test ===\n\n");

        start_watchdog();

        sharedObj = [[AtomicPropObj alloc] init];
        sharedObj.propA = @"Hello";
        sharedObj.propB = @"World";

        /* Launch threads that copy in opposite directions */
        pthread_t t1, t2;
        pthread_create(&t1, NULL, copy_a_to_b, NULL);
        pthread_create(&t2, NULL, copy_b_to_a, NULL);

        pthread_join(t1, NULL);
        pthread_join(t2, NULL);

        TEST_ASSERT(1, "no deadlock: bidirectional atomic copy completed");

        /* Verify properties still hold valid strings */
        TEST_ASSERT_NOT_NULL(sharedObj.propA,
                             "propA is not nil after stress test");
        TEST_ASSERT_NOT_NULL(sharedObj.propB,
                             "propB is not nil after stress test");

        printf("Final propA: %s\n", [sharedObj.propA UTF8String]);
        printf("Final propB: %s\n", [sharedObj.propB UTF8String]);
    }

    return TEST_SUMMARY();
}
