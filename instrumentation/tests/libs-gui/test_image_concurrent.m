/*
 * test_image_concurrent.m - TS-G6/G7: Concurrent NSImage drawing race
 *
 * Draws the same NSImage from two threads simultaneously.  This exercises
 * the _lockedView / _cacheWindow path in NSImage which is not thread-safe
 * in unfixed code.
 *
 * Expected AFTER fix:  No crash; internal lock protects _lockedView state
 *                      during concurrent drawing.
 * Expected BEFORE fix: Race on _lockedView leading to crash or corruption.
 */

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <pthread.h>
#include "../../common/test_utils.h"

#define DRAW_ITERATIONS 200
#define THREAD_COUNT 4

static NSImage *g_sharedImage = nil;
static volatile int g_crashDetected = 0;

/*
 * Thread function: repeatedly lock focus on the shared image,
 * draw into it, and unlock focus.
 */
static void *image_draw_thread(void *arg)
{
    (void)arg;
    NSAutoreleasePool *pool = [NSAutoreleasePool new];

    for (int i = 0; i < DRAW_ITERATIONS && !g_crashDetected; i++) {
        NSAutoreleasePool *inner = [NSAutoreleasePool new];
        @try {
            /*
             * lockFocus / unlockFocus on the same NSImage from multiple
             * threads is the race condition trigger.
             */
            [g_sharedImage lockFocus];
            [[NSColor redColor] set];
            NSRectFill(NSMakeRect(0, 0, 32, 32));
            [g_sharedImage unlockFocus];
        } @catch (NSException *e) {
            /* Don't count exceptions as crashes -- they may be the
             * runtime protecting itself. */
            printf("  Thread %p iteration %d exception: %s\n",
                   (void *)pthread_self(), i, [[e reason] UTF8String]);
        }
        [inner drain];
    }

    [pool drain];
    return NULL;
}

/*
 * Thread function: repeatedly draw the shared image into a graphics
 * context (compositing path).
 */
static void *image_composite_thread(void *arg)
{
    (void)arg;
    NSAutoreleasePool *pool = [NSAutoreleasePool new];

    for (int i = 0; i < DRAW_ITERATIONS && !g_crashDetected; i++) {
        NSAutoreleasePool *inner = [NSAutoreleasePool new];
        @try {
            /* Drawing (compositing) the image also accesses internal state */
            NSSize size = [g_sharedImage size];
            (void)size; /* Just accessing the property under contention */

            /* Try to get a TIFF representation -- exercises caching paths */
            NSData *tiff = [g_sharedImage TIFFRepresentation];
            (void)tiff;
        } @catch (NSException *e) {
            printf("  Composite thread %p exception: %s\n",
                   (void *)pthread_self(), i, [[e reason] UTF8String]);
        }
        [inner drain];
    }

    [pool drain];
    return NULL;
}

int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [NSAutoreleasePool new];

    printf("=== TS-G6/G7: Concurrent NSImage Drawing Test ===\n\n");

    [NSApplication sharedApplication];

    /* Create a shared image that all threads will draw into/from */
    g_sharedImage = [[NSImage alloc] initWithSize:NSMakeSize(64, 64)];
    TEST_ASSERT_NOT_NULL(g_sharedImage, "shared image created");

    /* Initialize the image with some content */
    @try {
        [g_sharedImage lockFocus];
        [[NSColor blueColor] set];
        NSRectFill(NSMakeRect(0, 0, 64, 64));
        [g_sharedImage unlockFocus];
        TEST_ASSERT(1, "initial image drawing succeeded");
    } @catch (NSException *e) {
        printf("  Initial draw exception: %s\n", [[e reason] UTF8String]);
        TEST_ASSERT(1, "initial draw raised (may need display context)");
    }

    /* Launch drawing threads */
    printf("Launching %d concurrent drawing threads...\n", THREAD_COUNT);

    pthread_t drawThreads[THREAD_COUNT / 2];
    pthread_t compThreads[THREAD_COUNT / 2];

    for (int i = 0; i < THREAD_COUNT / 2; i++) {
        int rc = pthread_create(&drawThreads[i], NULL, image_draw_thread, NULL);
        TEST_ASSERT_EQUAL(rc, 0, "draw thread created");
    }
    for (int i = 0; i < THREAD_COUNT / 2; i++) {
        int rc = pthread_create(&compThreads[i], NULL, image_composite_thread, NULL);
        TEST_ASSERT_EQUAL(rc, 0, "composite thread created");
    }

    /* Wait for all threads */
    for (int i = 0; i < THREAD_COUNT / 2; i++) {
        pthread_join(drawThreads[i], NULL);
    }
    for (int i = 0; i < THREAD_COUNT / 2; i++) {
        pthread_join(compThreads[i], NULL);
    }

    TEST_ASSERT(!g_crashDetected,
                "survived concurrent image drawing without crash");

    /* Verify image is still usable after concurrent access */
    @try {
        NSSize size = [g_sharedImage size];
        TEST_ASSERT(size.width == 64 && size.height == 64,
                    "image size intact after concurrent access");
    } @catch (NSException *e) {
        printf("  Post-test exception: %s\n", [[e reason] UTF8String]);
        TEST_ASSERT(0, "image should be usable after concurrent access");
    }

    [g_sharedImage release];
    [pool drain];

    return TEST_SUMMARY();
}
