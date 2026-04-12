/*
 * bench_scroll.m - Scroll performance benchmark
 *
 * Simulates scrolling by repeatedly calling setBoundsOrigin: on
 * NSClipView. Measures frame rate equivalent.
 *
 * Targets: scroll overdraw optimization
 *
 * Usage: ./bench_scroll [--json]
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include "bench_harness.h"

#define SCROLL_ITERS 10000
#define SCROLL_STEP  5.0

@interface ScrollContentView : NSView
@end

@implementation ScrollContentView
- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)rect {
    /* Draw alternating colored rows to simulate content */
    int startRow = (int)(rect.origin.y / 20.0);
    int endRow = (int)((rect.origin.y + rect.size.height) / 20.0) + 1;
    for (int row = startRow; row <= endRow; row++) {
        if (row % 2 == 0) {
            [[NSColor lightGrayColor] set];
        } else {
            [[NSColor whiteColor] set];
        }
        NSRectFill(NSMakeRect(0, row * 20, rect.size.width, 20));
    }
}
@end

int main(int argc, char *argv[]) {
    int json = (argc > 1 && strcmp(argv[1], "--json") == 0);

    @autoreleasepool {
        [NSApplication sharedApplication];

        /* Create a window with a scroll view */
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 400, 300)
                      styleMask:NSWindowStyleMaskTitled
                        backing:NSBackingStoreBuffered
                          defer:YES];

        NSScrollView *scrollView = [[NSScrollView alloc]
            initWithFrame:[[window contentView] bounds]];
        [scrollView setHasVerticalScroller:YES];
        [scrollView setHasHorizontalScroller:NO];

        /* Large document view (much taller than visible area) */
        ScrollContentView *docView = [[ScrollContentView alloc]
            initWithFrame:NSMakeRect(0, 0, 400, 50000)];
        [scrollView setDocumentView:docView];
        [[window contentView] addSubview:scrollView];

        NSClipView *clipView = [scrollView contentView];

        /* Benchmark 1: Scroll down (sequential small steps) */
        if (json) {
            BENCH_JSON("scroll_down_step", SCROLL_ITERS, {
                NSPoint current = [clipView bounds].origin;
                current.y += SCROLL_STEP;
                [clipView setBoundsOrigin:current];
            });
        } else {
            BENCH("scroll_down_step", SCROLL_ITERS, {
                NSPoint current = [clipView bounds].origin;
                current.y += SCROLL_STEP;
                [clipView setBoundsOrigin:current];
            });
        }

        /* Reset scroll position */
        [clipView setBoundsOrigin:NSMakePoint(0, 0)];

        /* Benchmark 2: Scroll with display (includes redraw) */
        if (json) {
            BENCH_JSON("scroll_down_display", SCROLL_ITERS / 10, {
                NSPoint current = [clipView bounds].origin;
                current.y += SCROLL_STEP;
                [clipView setBoundsOrigin:current];
                [scrollView displayIfNeeded];
            });
        } else {
            BENCH("scroll_down_display", SCROLL_ITERS / 10, {
                NSPoint current = [clipView bounds].origin;
                current.y += SCROLL_STEP;
                [clipView setBoundsOrigin:current];
                [scrollView displayIfNeeded];
            });
        }

        /* Reset */
        [clipView setBoundsOrigin:NSMakePoint(0, 0)];

        /* Benchmark 3: Large jump scrolling */
        if (json) {
            BENCH_JSON("scroll_jump", SCROLL_ITERS, {
                double offset = (_bench_i % 1000) * 50.0;
                [clipView setBoundsOrigin:NSMakePoint(0, offset)];
            });
        } else {
            BENCH("scroll_jump", SCROLL_ITERS, {
                double offset = (_bench_i % 1000) * 50.0;
                [clipView setBoundsOrigin:NSMakePoint(0, offset)];
            });
        }

        /* Benchmark 4: Scroll up (reverse direction) */
        [clipView setBoundsOrigin:NSMakePoint(0, 49000)];
        if (json) {
            BENCH_JSON("scroll_up_step", SCROLL_ITERS, {
                NSPoint current = [clipView bounds].origin;
                current.y -= SCROLL_STEP;
                if (current.y < 0) current.y = 49000;
                [clipView setBoundsOrigin:current];
            });
        } else {
            BENCH("scroll_up_step", SCROLL_ITERS, {
                NSPoint current = [clipView bounds].origin;
                current.y -= SCROLL_STEP;
                if (current.y < 0) current.y = 49000;
                [clipView setBoundsOrigin:current];
            });
        }

        [docView release];
        [scrollView release];
        [window release];
    }

    return 0;
}
