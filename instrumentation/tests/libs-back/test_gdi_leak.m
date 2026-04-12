/*
 * test_gdi_leak.m - RB-B5: GDI handle leak on Windows
 *
 * Windows-only test.  Creates, resizes, and destroys windows N times,
 * counting GDI object handles before and after.  A leak means the
 * backend is not releasing GDI resources (HDC, HBITMAP, HPEN, etc.)
 * when windows are destroyed or resized.
 *
 * Expected AFTER fix:  GDI handle count returns to baseline (zero leak).
 * Expected BEFORE fix: GDI handles accumulate, eventually exhausting
 *                      the per-process GDI limit (10,000 default).
 *
 * On non-Windows platforms, this test passes trivially (not applicable).
 */

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include "../../common/test_utils.h"

#ifdef _WIN32
#include <windows.h>

/*
 * GetGuiResources returns the count of GDI or USER objects for a process.
 * GR_GDIOBJECTS = 0, GR_USEROBJECTS = 1
 */
#ifndef GR_GDIOBJECTS
#define GR_GDIOBJECTS 0
#endif

#define WINDOW_CYCLES 50
#define RESIZE_CYCLES 10
#define ACCEPTABLE_LEAK 5  /* Allow a few handles for framework internals */

static DWORD get_gdi_count(void)
{
    return GetGuiResources(GetCurrentProcess(), GR_GDIOBJECTS);
}

#endif /* _WIN32 */

int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [NSAutoreleasePool new];

    printf("=== RB-B5: GDI Handle Leak Test ===\n\n");

#ifndef _WIN32
    printf("  Not running on Windows -- test not applicable.\n");
    TEST_ASSERT(1, "GDI leak test skipped (non-Windows platform)");
    [pool drain];
    return TEST_SUMMARY();
#else

    [NSApplication sharedApplication];

    /*
     * Warm up: create and destroy a few windows to let the framework
     * allocate any one-time resources.
     */
    printf("Warming up...\n");
    for (int i = 0; i < 5; i++) {
        NSAutoreleasePool *inner = [NSAutoreleasePool new];
        @try {
            NSWindow *win = [[NSWindow alloc]
                initWithContentRect:NSMakeRect(0, 0, 200, 150)
                          styleMask:NSWindowStyleMaskTitled
                            backing:NSBackingStoreBuffered
                              defer:NO];
            [win orderFront:nil];
            [win close];
        } @catch (NSException *e) {
            /* Ignore warmup failures */
        }
        [inner drain];
    }

    /* Measure baseline GDI count */
    DWORD gdiBaseline = get_gdi_count();
    printf("GDI baseline: %lu handles\n", (unsigned long)gdiBaseline);

    /*
     * Test 1: Create/destroy cycle
     */
    printf("\nTest 1: Create/destroy %d windows...\n", WINDOW_CYCLES);
    for (int i = 0; i < WINDOW_CYCLES; i++) {
        NSAutoreleasePool *inner = [NSAutoreleasePool new];
        @try {
            NSWindow *win = [[NSWindow alloc]
                initWithContentRect:NSMakeRect(i % 10 * 20, i % 10 * 20,
                                               200 + i, 150 + i)
                          styleMask:(NSWindowStyleMaskTitled |
                                     NSWindowStyleMaskClosable |
                                     NSWindowStyleMaskResizable)
                            backing:NSBackingStoreBuffered
                              defer:NO];

            NSView *cv = [[NSView alloc]
                initWithFrame:NSMakeRect(0, 0, 200 + i, 150 + i)];
            [win setContentView:cv];
            [cv release];

            [win orderFront:nil];
            [win display];
            [win close];
        } @catch (NSException *e) {
            /* Continue -- we're measuring handle leaks */
        }
        [inner drain];
    }

    DWORD gdiAfterCreate = get_gdi_count();
    long createLeak = (long)gdiAfterCreate - (long)gdiBaseline;
    printf("GDI after create/destroy: %lu (delta: %ld)\n",
           (unsigned long)gdiAfterCreate, createLeak);

    TEST_ASSERT(createLeak <= ACCEPTABLE_LEAK,
                "GDI handles not leaked after create/destroy cycles");

    /*
     * Test 2: Resize cycle (resizing can leak backing store bitmaps)
     */
    printf("\nTest 2: Resize a window %d times...\n", RESIZE_CYCLES);
    DWORD gdiBeforeResize = get_gdi_count();

    @try {
        NSWindow *win = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(50, 50, 200, 150)
                      styleMask:(NSWindowStyleMaskTitled |
                                 NSWindowStyleMaskResizable)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        [win orderFront:nil];

        for (int i = 0; i < RESIZE_CYCLES; i++) {
            [win setFrame:NSMakeRect(50, 50, 200 + i * 10, 150 + i * 5)
                  display:YES];
        }

        [win close];
    } @catch (NSException *e) {
        printf("  Resize test exception: %s\n", [[e reason] UTF8String]);
    }

    DWORD gdiAfterResize = get_gdi_count();
    long resizeLeak = (long)gdiAfterResize - (long)gdiBeforeResize;
    printf("GDI after resize: %lu (delta: %ld)\n",
           (unsigned long)gdiAfterResize, resizeLeak);

    TEST_ASSERT(resizeLeak <= ACCEPTABLE_LEAK,
                "GDI handles not leaked after resize cycles");

    /*
     * Test 3: Total leak assessment
     */
    DWORD gdiFinal = get_gdi_count();
    long totalLeak = (long)gdiFinal - (long)gdiBaseline;
    printf("\nFinal GDI count: %lu (total delta from baseline: %ld)\n",
           (unsigned long)gdiFinal, totalLeak);

    TEST_ASSERT(totalLeak <= ACCEPTABLE_LEAK,
                "total GDI handle leak within acceptable bounds");

    [pool drain];
    return TEST_SUMMARY();
#endif /* _WIN32 */
}
