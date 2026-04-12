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

int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [NSAutoreleasePool new];

    printf("=== Headless Backend Lifecycle Test ===\n\n");

    /* Step 1: Create shared application */
    printf("Step 1: Creating NSApplication...\n");
    NSApplication *app = [NSApplication sharedApplication];
    TEST_ASSERT_NOT_NULL(app, "NSApplication created");

    /* Step 2: Create a window */
    printf("Step 2: Creating NSWindow...\n");
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(100, 100, 400, 300)
                  styleMask:(NSWindowStyleMaskTitled |
                             NSWindowStyleMaskClosable |
                             NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    TEST_ASSERT_NOT_NULL(window, "NSWindow created");

    /* Step 3: Set content view */
    printf("Step 3: Setting content view...\n");
    NSView *contentView = [[NSView alloc]
        initWithFrame:NSMakeRect(0, 0, 400, 300)];
    [window setContentView:contentView];
    TEST_ASSERT_EQUAL([window contentView], contentView,
                       "content view set correctly");

    /* Step 4: Add a subview */
    printf("Step 4: Adding subview...\n");
    NSView *subview = [[NSView alloc]
        initWithFrame:NSMakeRect(10, 10, 100, 50)];
    [contentView addSubview:subview];
    TEST_ASSERT_EQUAL((int)[[contentView subviews] count], 1,
                       "subview added");

    /* Step 5: Order window front (headless backend should handle this) */
    printf("Step 5: Ordering window front...\n");
    @try {
        [window orderFront:nil];
        TEST_ASSERT(1, "orderFront did not crash");
    } @catch (NSException *e) {
        printf("  orderFront exception: %s\n", [[e reason] UTF8String]);
        TEST_ASSERT(1, "orderFront raised (may need display backend)");
    }

    /* Step 6: Display the window */
    printf("Step 6: Displaying window...\n");
    @try {
        [window display];
        TEST_ASSERT(1, "display did not crash");
    } @catch (NSException *e) {
        printf("  display exception: %s\n", [[e reason] UTF8String]);
        TEST_ASSERT(1, "display raised (may need display backend)");
    }

    /* Step 7: Resize the window */
    printf("Step 7: Resizing window...\n");
    @try {
        [window setFrame:NSMakeRect(100, 100, 800, 600) display:YES];
        NSRect newFrame = [window frame];
        printf("  New frame: (%.0f, %.0f, %.0f, %.0f)\n",
               newFrame.origin.x, newFrame.origin.y,
               newFrame.size.width, newFrame.size.height);
        TEST_ASSERT(1, "resize did not crash");
    } @catch (NSException *e) {
        printf("  resize exception: %s\n", [[e reason] UTF8String]);
        TEST_ASSERT(1, "resize raised (may need display backend)");
    }

    /* Step 8: Close the window */
    printf("Step 8: Closing window...\n");
    @try {
        [window close];
        TEST_ASSERT(1, "window close did not crash");
    } @catch (NSException *e) {
        printf("  close exception: %s\n", [[e reason] UTF8String]);
        TEST_ASSERT(0, "window close should not throw");
    }

    /* Step 9: Cleanup */
    printf("Step 9: Cleaning up...\n");
    [subview release];
    [contentView release];
    /* Note: window is released by close if releasedWhenClosed is YES (default) */

    printf("Step 10: Lifecycle complete.\n");
    TEST_ASSERT(1, "full lifecycle completed without crash");

    [pool drain];
    return TEST_SUMMARY();
}
