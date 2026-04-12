/*
 * test_cfrunloop_atomic.m - TS-1/2: CFRunLoop atomicity issues
 *
 * TS-1: _isWaiting flag in CFRunLoop is read/written without atomics,
 *       causing a TOCTOU race in CFRunLoopWakeUp.
 * TS-2: _stop flag similarly lacks atomic access.
 *
 * This test calls CFRunLoopWakeUp from background threads while the
 * run loop is running. If the race is severe, it may crash or hang.
 * The test passes if no crash occurs within a reasonable time.
 */

#import <Foundation/Foundation.h>
#include <CoreFoundation/CFRunLoop.h>
#include <pthread.h>
#include <unistd.h>

#include "../../common/test_utils.h"

static CFRunLoopRef mainLoop = NULL;
static volatile int shouldStop = 0;

static void *wakeup_thread(void *arg)
{
    (void)arg;
    /* Repeatedly wake up the main run loop from this thread */
    for (int i = 0; i < 1000 && !shouldStop; i++) {
        if (mainLoop != NULL) {
            CFRunLoopWakeUp(mainLoop);
        }
        /* Tiny yield to create interleaving */
        usleep(100);
    }
    return NULL;
}

static void timerCallback(CFRunLoopTimerRef timer, void *info)
{
    (void)timer;
    int *count = (int *)info;
    (*count)++;

    /* After enough timer fires, stop the run loop */
    if (*count >= 50) {
        shouldStop = 1;
        CFRunLoopStop(CFRunLoopGetCurrent());
    }
}

int main(void)
{
    @autoreleasepool {
        printf("=== test_cfrunloop_atomic (TS-1/2) ===\n");
        printf("Stress-tests CFRunLoopWakeUp from background threads.\n\n");

        mainLoop = CFRunLoopGetCurrent();
        int timerCount = 0;

        /* Create a repeating timer that fires frequently */
        CFRunLoopTimerContext ctx = { 0, &timerCount, NULL, NULL, NULL };
        CFRunLoopTimerRef timer = CFRunLoopTimerCreate(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + 0.01, /* fireDate */
            0.01,                                /* interval: 10ms */
            0, 0,
            timerCallback,
            &ctx);
        CFRunLoopAddTimer(mainLoop, timer, kCFRunLoopDefaultMode);

        /* Launch several background threads that call CFRunLoopWakeUp */
        #define NUM_WAKERS 4
        pthread_t threads[NUM_WAKERS];
        for (int i = 0; i < NUM_WAKERS; i++) {
            pthread_create(&threads[i], NULL, wakeup_thread, NULL);
        }

        /* Run the loop - this exercises the _isWaiting / _stop race */
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 5.0, false);

        /* Signal threads to stop and join */
        shouldStop = 1;
        for (int i = 0; i < NUM_WAKERS; i++) {
            pthread_join(threads[i], NULL);
        }

        CFRunLoopRemoveTimer(mainLoop, timer, kCFRunLoopDefaultMode);
        CFRelease(timer);

        /* If we got here without crashing, the atomicity issue did not
         * cause a fatal problem in this run. */
        TEST_ASSERT(timerCount > 0, "timer fired at least once");
        TEST_ASSERT(1, "no crash from concurrent CFRunLoopWakeUp");

        printf("  Timer fired %d times with %d concurrent waker threads.\n",
               timerCount, NUM_WAKERS);

        return TEST_SUMMARY();
    }
}
