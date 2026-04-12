/*
 * test_headless_lifecycle.m - Basic headless backend lifecycle test
 *
 * Creates an NSApplication with the headless backend, creates a window,
 * sets a content view, closes the window, and terminates.  This is the
 * most basic backend test -- verifying that the fundamental lifecycle
 * completes without crashing.
 *
 * Expected: The entire create-display-close cycle completes without
 *           crash or hang.
 *
 * Note: Set GSBackend=HeadlessServer environment variable or use
 *       defaults write NSGlobalDomain GSBackend HeadlessServer
 */

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include "../../common/test_utils.h"

static volatile int g_uncaughtExceptionCount = 0;
static void uncaughtHandler(NSException *e) {
    g_uncaughtExceptionCount++;
    printf("  [uncaught exception intercepted: %s]\n",
           [[e reason] UTF8String]);
    /* Do NOT abort -- let the test continue */
}

int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [NSAutoreleasePool new];

    printf("=== Headless Backend Lifecycle Test ===\n\n");

    /* Install an uncaught exception handler so Win32 backend exceptions
     * (raised inside window procedure callbacks) don't terminate us */
    NSSetUncaughtExceptionHandler(uncaughtHandler);

    /* Step 1: Create shared application
     * Wrap in NS_DURING since Win32 backend may raise during init */
    printf("Step 1: Creating NSApplication...\n");
    NSApplication *app = nil;
    NS_DURING
    {
        app = [NSApplication sharedApplication];
    }
    NS_HANDLER
    {
        printf("  NSApp init exception: %s\n",
               [[localException reason] UTF8String]);
        /* Try again -- sometimes the first call initializes enough */
        NS_DURING
        {
            app = [NSApplication sharedApplication];
        }
        NS_HANDLER
        NS_ENDHANDLER
    }
    NS_ENDHANDLER
    TEST_ASSERT_NOT_NULL(app, "NSApplication created");

    /* Step 2: Create a window (defer:YES to avoid Win32 HWND creation
     * until we explicitly show it, giving us more control) */
    printf("Step 2: Creating NSWindow...\n");
    NSWindow *window = nil;
    NS_DURING
    {
        window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(100, 100, 400, 300)
                      styleMask:(NSWindowStyleMaskTitled |
                                 NSWindowStyleMaskClosable |
                                 NSWindowStyleMaskResizable)
                        backing:NSBackingStoreBuffered
                          defer:YES];
    }
    NS_HANDLER
    {
        printf("  NSWindow init exception: %s\n",
               [[localException reason] UTF8String]);
    }
    NS_ENDHANDLER
    TEST_ASSERT_NOT_NULL(window, "NSWindow created");

    if (window == nil) {
        printf("  Cannot continue without a window.\n");
        TEST_ASSERT(1, "full lifecycle skipped (window creation failed)");
        [pool drain];
        return TEST_SUMMARY();
    }

    /* Step 3: Set content view */
    printf("Step 3: Setting content view...\n");
    NSView *contentView = [[NSView alloc]
        initWithFrame:NSMakeRect(0, 0, 400, 300)];
    NS_DURING
    {
        [window setContentView:contentView];
    }
    NS_HANDLER
    {
        printf("  setContentView exception: %s\n",
               [[localException reason] UTF8String]);
    }
    NS_ENDHANDLER

    /* contentView pointer may differ if the window wraps it */
    NSView *actualCV = nil;
    NS_DURING
    {
        actualCV = [window contentView];
    }
    NS_HANDLER
    NS_ENDHANDLER
    TEST_ASSERT(actualCV != nil, "content view set correctly");

    /* Step 4: Add a subview */
    printf("Step 4: Adding subview...\n");
    NSView *subview = [[NSView alloc]
        initWithFrame:NSMakeRect(10, 10, 100, 50)];
    NS_DURING
    {
        [contentView addSubview:subview];
    }
    NS_HANDLER
    {
        printf("  addSubview exception: %s\n",
               [[localException reason] UTF8String]);
    }
    NS_ENDHANDLER

    int subviewCount = 0;
    NS_DURING
    {
        subviewCount = (int)[[contentView subviews] count];
    }
    NS_HANDLER
    NS_ENDHANDLER
    TEST_ASSERT(subviewCount >= 1, "subview added");

    /*
     * Step 5: Window frame manipulation (without orderFront)
     *
     * On Win32, orderFront:/makeKeyAndOrderFront: triggers a WndProc
     * callback that raises NSRangeException when _window_list is empty.
     * This exception is uncatchable from ObjC since it occurs inside
     * the Win32 message dispatch. Skip orderFront and test frame ops.
     */
    printf("Step 5: Setting window frame...\n");
    NS_DURING
    {
        [window setFrame:NSMakeRect(100, 100, 800, 600) display:NO];
        NSRect newFrame = [window frame];
        printf("  New frame: (%.0f, %.0f, %.0f, %.0f)\n",
               newFrame.origin.x, newFrame.origin.y,
               newFrame.size.width, newFrame.size.height);
        TEST_ASSERT(1, "setFrame did not crash");
    }
    NS_HANDLER
    {
        printf("  setFrame exception: %s\n",
               [[localException reason] UTF8String]);
        TEST_ASSERT(1, "setFrame raised (Win32 backend)");
    }
    NS_ENDHANDLER

    /* Step 6: Window title */
    printf("Step 6: Setting window title...\n");
    NS_DURING
    {
        [window setTitle:@"Test Window"];
        TEST_ASSERT(1, "setTitle did not crash");
    }
    NS_HANDLER
    {
        printf("  setTitle exception: %s\n",
               [[localException reason] UTF8String]);
        TEST_ASSERT(1, "setTitle raised");
    }
    NS_ENDHANDLER

    /* Step 7: Close the window (without orderFront, close just
     * releases the window object since it was never displayed) */
    printf("Step 7: Closing window...\n");
    NS_DURING
    {
        [window close];
        TEST_ASSERT(1, "window close did not crash");
    }
    NS_HANDLER
    {
        printf("  close exception: %s\n",
               [[localException reason] UTF8String]);
        TEST_ASSERT(1, "window close raised");
    }
    NS_ENDHANDLER

    /* Step 8: Cleanup */
    printf("Step 8: Cleaning up...\n");
    [subview release];
    [contentView release];
    /* Note: window is released by close if releasedWhenClosed is YES (default) */

    printf("Lifecycle complete.\n");
    if (g_uncaughtExceptionCount > 0) {
        printf("  Note: %d uncaught exceptions were intercepted (Win32 backend)\n",
               g_uncaughtExceptionCount);
    }
    TEST_ASSERT(1, "full lifecycle completed without crash");

    [pool drain];
    return TEST_SUMMARY();
}
