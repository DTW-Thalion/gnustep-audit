/*
 * test_window_map_race.m - TS-B2: Window map table race condition
 *
 * Rapidly creates and destroys windows from multiple threads.  The backend
 * maintains an NSMapTable mapping window numbers/handles to window objects.
 * Without proper locking, concurrent insertion and removal corrupts the map.
 *
 * Expected AFTER fix:  NSMapTable is protected by a lock; no corruption.
 * Expected BEFORE fix: Map table corruption leading to crashes, dangling
 *                      pointers, or lost window references.
 */

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <pthread.h>
#include "../../common/test_utils.h"

#define WINDOWS_PER_THREAD 20
#define THREAD_COUNT 4

static volatile int g_errorCount = 0;

/*
 * Thread function: create and destroy windows rapidly.
 */
static void *window_lifecycle_thread(void *arg)
{
    int threadId = *(int *)arg;
    NSAutoreleasePool *pool = [NSAutoreleasePool new];

    for (int i = 0; i < WINDOWS_PER_THREAD; i++) {
        NSAutoreleasePool *inner = [NSAutoreleasePool new];
        @try {
            NSWindow *win = [[NSWindow alloc]
                initWithContentRect:NSMakeRect(threadId * 50, i * 10, 100, 80)
                          styleMask:(NSWindowStyleMaskTitled |
                                     NSWindowStyleMaskClosable)
                            backing:NSBackingStoreBuffered
                              defer:NO];

            if (win == nil) {
                printf("  Thread %d: window %d creation returned nil\n",
                       threadId, i);
                __sync_fetch_and_add(&g_errorCount, 1);
                [inner drain];
                continue;
            }

            /* Set a content view to exercise more map table paths */
            NSView *cv = [[NSView alloc]
                initWithFrame:NSMakeRect(0, 0, 100, 80)];
            [win setContentView:cv];
            [cv release];

            /* Brief display attempt */
            @try {
                [win orderFront:nil];
            } @catch (NSException *e) {
                /* May fail without display -- OK */
            }

            /* Close destroys the window handle and removes from map */
            [win close];
            /* Window is released by close if releasedWhenClosed (default) */

        } @catch (NSException *e) {
            printf("  Thread %d window %d exception: %s\n",
                   threadId, i, [[e reason] UTF8String]);
            __sync_fetch_and_add(&g_errorCount, 1);
        }
        [inner drain];
    }

    [pool drain];
    return NULL;
}

int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [NSAutoreleasePool new];

    printf("=== TS-B2: Window Map Table Race Test ===\n\n");

    [NSApplication sharedApplication];

    printf("Creating/destroying %d windows across %d threads...\n",
           WINDOWS_PER_THREAD * THREAD_COUNT, THREAD_COUNT);

    pthread_t threads[THREAD_COUNT];
    int threadIds[THREAD_COUNT];

    for (int i = 0; i < THREAD_COUNT; i++) {
        threadIds[i] = i;
        int rc = pthread_create(&threads[i], NULL,
                                window_lifecycle_thread, &threadIds[i]);
        TEST_ASSERT_EQUAL(rc, 0, "thread created");
    }

    for (int i = 0; i < THREAD_COUNT; i++) {
        pthread_join(threads[i], NULL);
    }

    printf("Completed. Errors: %d\n", g_errorCount);

    /*
     * The primary assertion is that we didn't crash.  Map table corruption
     * in the unfixed code typically manifests as a SIGSEGV/SIGBUS during
     * the test run.
     */
    TEST_ASSERT(1, "survived concurrent window create/destroy without crash");

    /*
     * Secondary: check that errors are within acceptable limits.
     * Some exceptions are expected when running without a display backend.
     */
    TEST_ASSERT(g_errorCount < WINDOWS_PER_THREAD * THREAD_COUNT,
                "not all windows failed (some succeeded)");

    [pool drain];
    return TEST_SUMMARY();
}
