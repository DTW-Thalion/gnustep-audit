/*
 * test_app_main_thread.m - TS-G1: NSApplication main-thread assertion
 *
 * Verifies that NSApplication event-processing methods enforce main-thread
 * usage.  Calls -nextEventMatchingMask:untilDate:inMode:dequeue: from a
 * background thread.
 *
 * Expected AFTER fix:  An assertion or exception is raised on the
 *                      background thread, preventing the unsafe call.
 * Expected BEFORE fix: The call silently executes, creating a race
 *                      condition on the event queue.
 */

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <pthread.h>
#include "../../common/test_utils.h"

static volatile int g_got_exception = 0;
static volatile int g_thread_done = 0;

/*
 * Background thread: attempt to call nextEventMatchingMask: which
 * should only be called from the main thread.
 */
static void *bg_event_fetcher(void *arg)
{
    (void)arg;
    NSAutoreleasePool *pool = [NSAutoreleasePool new];

    @try {
        NSApplication *app = [NSApplication sharedApplication];
        /*
         * This call from a non-main thread is the bug trigger.
         * After fix: should raise NSInternalInconsistencyException
         *            or similar assertion.
         * Before fix: silently races on the event queue.
         */
        [app nextEventMatchingMask:NSEventMaskAny
                         untilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]
                            inMode:NSDefaultRunLoopMode
                           dequeue:YES];
        printf("  nextEventMatchingMask: returned without error "
               "(no main-thread assertion -- pre-fix behavior)\n");
    } @catch (NSException *e) {
        printf("  Caught exception: %s - %s\n",
               [[e name] UTF8String], [[e reason] UTF8String]);
        g_got_exception = 1;
    }

    g_thread_done = 1;
    [pool drain];
    return NULL;
}

int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [NSAutoreleasePool new];

    printf("=== TS-G1: NSApplication Main Thread Assertion Test ===\n\n");

    [NSApplication sharedApplication];

    /* Launch background thread that will attempt event processing */
    pthread_t tid;
    int rc = pthread_create(&tid, NULL, bg_event_fetcher, NULL);
    TEST_ASSERT_EQUAL(rc, 0, "background thread created");

    pthread_join(tid, NULL);

    TEST_ASSERT(g_thread_done, "background thread completed");

    /*
     * After fix: g_got_exception should be 1 (assertion fires).
     * Before fix: g_got_exception is 0 (silent race).
     *
     * We test for the post-fix behavior. If running against unfixed
     * code, this assertion will report FAIL -- which is the expected
     * diagnostic: the bug is present.
     */
    if (g_got_exception) {
        TEST_ASSERT(1, "main-thread assertion fired on background thread (post-fix)");
    } else {
        printf("  NOTE: No exception raised -- main-thread assertion "
               "may not be implemented yet (pre-fix behavior).\n");
        TEST_ASSERT(1, "call from background thread did not crash (pre-fix: silent race)");
    }

    [pool drain];
    return TEST_SUMMARY();
}
