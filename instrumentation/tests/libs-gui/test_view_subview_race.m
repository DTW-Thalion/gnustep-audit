/*
 * test_view_subview_race.m - TS-G2: Subview add/remove race during display
 *
 * Creates an NSView with subviews. A background thread adds and removes
 * subviews while the main thread calls display. This exercises the
 * subview array mutation during enumeration path.
 *
 * Expected AFTER fix:  Display uses a snapshot of the subview array;
 *                      no crash or corruption.
 * Expected BEFORE fix: Crash due to mutating subview array during
 *                      enumeration in -display or -drawRect:.
 */

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <pthread.h>
#include "../../common/test_utils.h"

#define ITERATION_COUNT 500

static volatile int g_running = 1;
static NSView *g_parentView = nil;

/*
 * Background thread: rapidly add and remove subviews.
 */
static void *subview_mutator_thread(void *arg)
{
    (void)arg;
    NSAutoreleasePool *pool = [NSAutoreleasePool new];

    for (int i = 0; i < ITERATION_COUNT && g_running; i++) {
        NSAutoreleasePool *inner = [NSAutoreleasePool new];

        NSView *child = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
        @try {
            [g_parentView addSubview:child];
            /* Brief yield to let main thread display */
            [NSThread sleepForTimeInterval:0.0001];
            [child removeFromSuperview];
        } @catch (NSException *e) {
            /* Swallow -- we are probing for crashes, not exceptions */
        }
        [child release];
        [inner drain];
    }

    [pool drain];
    return NULL;
}

int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [NSAutoreleasePool new];

    printf("=== TS-G2: View Subview Race Test ===\n\n");

    /* We need an NSApplication for AppKit to function, but we do NOT
     * run the event loop.  Use the headless backend if available. */
    [NSApplication sharedApplication];

    /* Parent view with a few initial children */
    g_parentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 200)];
    TEST_ASSERT_NOT_NULL(g_parentView, "parent view created");

    for (int i = 0; i < 5; i++) {
        NSView *child = [[NSView alloc]
            initWithFrame:NSMakeRect(i * 10, 0, 10, 10)];
        [g_parentView addSubview:child];
        [child release];
    }

    TEST_ASSERT_EQUAL((int)[[g_parentView subviews] count], 5,
                       "initial subview count is 5");

    /* Launch mutator thread */
    pthread_t tid;
    int rc = pthread_create(&tid, NULL, subview_mutator_thread, NULL);
    TEST_ASSERT_EQUAL(rc, 0, "mutator thread created");

    /* Main thread: call display repeatedly while subviews are mutated */
    for (int i = 0; i < ITERATION_COUNT; i++) {
        @try {
            [g_parentView display];
        } @catch (NSException *e) {
            /* Not a crash -- but note the exception */
            printf("  Exception during display: %s\n",
                   [[e reason] UTF8String]);
        }
    }

    g_running = 0;
    pthread_join(tid, NULL);

    /* If we reach here, the race did not cause a crash */
    TEST_ASSERT(1, "survived concurrent subview mutation during display");

    /* Cleanup */
    [g_parentView release];
    [pool drain];

    return TEST_SUMMARY();
}
