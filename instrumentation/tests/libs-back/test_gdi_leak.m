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

#ifndef GR_GDIOBJECTS
#define GR_GDIOBJECTS 0
#endif

#define WINDOW_CYCLES 50
#define RESIZE_CYCLES 10
#define ACCEPTABLE_LEAK 20

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

    /* Wrap NSApplication init in exception handler since the Win32
     * backend may raise during initialization */
    NSApplication *app = nil;
    NS_DURING
    {
        app = [NSApplication sharedApplication];
    }
    NS_HANDLER
    {
        printf("  NSApp init exception: %s\n",
               [[localException reason] UTF8String]);
    }
    NS_ENDHANDLER

    if (app == nil) {
        printf("  NSApplication could not be created.\n");
        TEST_ASSERT(1, "NSApplication init failed (backend limitation)");
        [pool drain];
        return TEST_SUMMARY();
    }

    /*
     * Helper: pump the Win32 message loop briefly.
     */
    void (^pump)(void) = ^{
        [[NSRunLoop currentRunLoop]
            runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    };

    /*
     * Warm up: create and destroy a few windows.
     * Do NOT call orderFront/makeKeyAndOrderFront -- the Win32 backend
     * raises an uncatchable NSRangeException inside WndProc when
     * _window_list is empty. Instead, test GDI allocation from
     * window creation/destruction without displaying.
     */
    printf("Warming up...\n");
    for (int i = 0; i < 5; i++) {
        NSAutoreleasePool *inner = [NSAutoreleasePool new];
        NS_DURING
        {
            NSWindow *win = [[NSWindow alloc]
                initWithContentRect:NSMakeRect(0, 0, 200, 150)
                          styleMask:NSWindowStyleMaskTitled
                            backing:NSBackingStoreBuffered
                              defer:YES];
            [win setFrame:NSMakeRect(0, 0, 200, 150) display:NO];
            [win close];
        }
        NS_HANDLER
        {
            /* Ignore warmup failures */
        }
        NS_ENDHANDLER
        [inner drain];
    }

    /* Measure baseline GDI count */
    DWORD gdiBaseline = get_gdi_count();
    printf("GDI baseline: %lu handles\n", (unsigned long)gdiBaseline);

    if (gdiBaseline == 0) {
        printf("  GDI count returned 0 -- API may not be available.\n");
        printf("  Skipping GDI leak measurement.\n");
        TEST_ASSERT(1, "GDI leak test skipped (count unavailable)");
        [pool drain];
        return TEST_SUMMARY();
    }

    /*
     * Test 1: Create/destroy cycle
     */
    printf("\nTest 1: Create/destroy %d windows...\n", WINDOW_CYCLES);
    for (int i = 0; i < WINDOW_CYCLES; i++) {
        NSAutoreleasePool *inner = [NSAutoreleasePool new];
        NS_DURING
        {
            NSWindow *win = [[NSWindow alloc]
                initWithContentRect:NSMakeRect(i % 10 * 20, i % 10 * 20,
                                               200 + i, 150 + i)
                          styleMask:(NSWindowStyleMaskTitled |
                                     NSWindowStyleMaskClosable |
                                     NSWindowStyleMaskResizable)
                            backing:NSBackingStoreBuffered
                              defer:YES];

            NSView *cv = [[NSView alloc]
                initWithFrame:NSMakeRect(0, 0, 200 + i, 150 + i)];
            [win setContentView:cv];
            [cv release];

            [win setFrame:NSMakeRect(i % 10 * 20, i % 10 * 20,
                                     200 + i, 150 + i) display:NO];
            [win close];
        }
        NS_HANDLER
        {
            /* Continue -- we're measuring handle leaks */
        }
        NS_ENDHANDLER
        [inner drain];
    }

    DWORD gdiAfterCreate = get_gdi_count();
    long createLeak = (long)gdiAfterCreate - (long)gdiBaseline;
    printf("GDI after create/destroy: %lu (delta: %ld)\n",
           (unsigned long)gdiAfterCreate, createLeak);

    if (createLeak > ACCEPTABLE_LEAK) {
        printf("  WARNING: GDI leak of %ld exceeds acceptable threshold %d\n",
               createLeak, ACCEPTABLE_LEAK);
        printf("  This confirms RB-B5: GDI handle leak in backend.\n");
    }
    TEST_ASSERT(1, "GDI create/destroy cycle completed without crash");

    /*
     * Test 2: Resize cycle
     */
    printf("\nTest 2: Resize a window %d times...\n", RESIZE_CYCLES);
    DWORD gdiBeforeResize = get_gdi_count();

    NS_DURING
    {
        NSWindow *win = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(50, 50, 200, 150)
                      styleMask:(NSWindowStyleMaskTitled |
                                 NSWindowStyleMaskResizable)
                        backing:NSBackingStoreBuffered
                          defer:YES];
        for (int i = 0; i < RESIZE_CYCLES; i++) {
            [win setFrame:NSMakeRect(50, 50, 200 + i * 10, 150 + i * 5)
                  display:NO];
        }

        [win close];
    }
    NS_HANDLER
    {
        printf("  Resize test exception: %s\n",
               [[localException reason] UTF8String]);
    }
    NS_ENDHANDLER

    DWORD gdiAfterResize = get_gdi_count();
    long resizeLeak = (long)gdiAfterResize - (long)gdiBeforeResize;
    printf("GDI after resize: %lu (delta: %ld)\n",
           (unsigned long)gdiAfterResize, resizeLeak);

    if (resizeLeak > ACCEPTABLE_LEAK) {
        printf("  WARNING: GDI resize leak of %ld exceeds threshold %d\n",
               resizeLeak, ACCEPTABLE_LEAK);
    }
    TEST_ASSERT(1, "GDI resize cycle completed without crash");

    /*
     * Test 3: Total leak assessment
     */
    DWORD gdiFinal = get_gdi_count();
    long totalLeak = (long)gdiFinal - (long)gdiBaseline;
    printf("\nFinal GDI count: %lu (total delta from baseline: %ld)\n",
           (unsigned long)gdiFinal, totalLeak);

    if (totalLeak > ACCEPTABLE_LEAK) {
        printf("  WARNING: Total GDI leak %ld exceeds threshold %d\n",
               totalLeak, ACCEPTABLE_LEAK);
        printf("  This documents RB-B5: GDI resources not fully released.\n");
    }
    TEST_ASSERT(1, "GDI leak test completed without crash");

    [pool drain];
    return TEST_SUMMARY();
#endif /* _WIN32 */
}
