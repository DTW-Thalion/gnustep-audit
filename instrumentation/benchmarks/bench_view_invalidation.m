/*
 * bench_view_invalidation.m - View invalidation / display cycle benchmark
 *
 * Creates 100 NSViews, invalidates random subsets, and measures
 * display cycle time.
 *
 * Targets: dirty region list optimization
 *
 * Usage: ./bench_view_invalidation [--json]
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include "bench_harness.h"

#define VIEW_COUNT  100
#define ITERATIONS  10000

@interface BenchView : NSView
@end

@implementation BenchView
- (void)drawRect:(NSRect)rect {
    /* Minimal draw: fill with white */
    [[NSColor whiteColor] set];
    NSRectFill(rect);
}
@end

int main(int argc, char *argv[]) {
    int json = (argc > 1 && strcmp(argv[1], "--json") == 0);

    @autoreleasepool {
        /* We need an NSApplication for AppKit to function */
        [NSApplication sharedApplication];

        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 800, 600)
                      styleMask:NSWindowStyleMaskTitled
                        backing:NSBackingStoreBuffered
                          defer:YES];
        NSView *contentView = [window contentView];

        /* Create 100 subviews in a grid */
        NSMutableArray *views = [NSMutableArray arrayWithCapacity:VIEW_COUNT];
        for (int i = 0; i < VIEW_COUNT; i++) {
            int row = i / 10;
            int col = i % 10;
            NSRect frame = NSMakeRect(col * 80, row * 60, 75, 55);
            BenchView *v = [[BenchView alloc] initWithFrame:frame];
            [contentView addSubview:v];
            [views addObject:v];
            [v release];
        }

        /* Benchmark 1: Invalidate all views */
        if (json) {
            BENCH_JSON("view_invalidate_all", ITERATIONS, {
                for (int j = 0; j < VIEW_COUNT; j++) {
                    [[views objectAtIndex:(NSUInteger)j] setNeedsDisplay:YES];
                }
            });
        } else {
            BENCH("view_invalidate_all", ITERATIONS, {
                for (int j = 0; j < VIEW_COUNT; j++) {
                    [[views objectAtIndex:(NSUInteger)j] setNeedsDisplay:YES];
                }
            });
        }

        /* Benchmark 2: Invalidate random subset (every 3rd view) */
        if (json) {
            BENCH_JSON("view_invalidate_subset", ITERATIONS, {
                for (int j = 0; j < VIEW_COUNT; j += 3) {
                    [[views objectAtIndex:(NSUInteger)j] setNeedsDisplay:YES];
                }
            });
        } else {
            BENCH("view_invalidate_subset", ITERATIONS, {
                for (int j = 0; j < VIEW_COUNT; j += 3) {
                    [[views objectAtIndex:(NSUInteger)j] setNeedsDisplay:YES];
                }
            });
        }

        /* Benchmark 3: Invalidate specific rects */
        if (json) {
            BENCH_JSON("view_invalidate_rect", ITERATIONS, {
                for (int j = 0; j < VIEW_COUNT; j += 5) {
                    NSView *v = [views objectAtIndex:(NSUInteger)j];
                    [v setNeedsDisplayInRect:NSMakeRect(10, 10, 30, 30)];
                }
            });
        } else {
            BENCH("view_invalidate_rect", ITERATIONS, {
                for (int j = 0; j < VIEW_COUNT; j += 5) {
                    NSView *v = [views objectAtIndex:(NSUInteger)j];
                    [v setNeedsDisplayInRect:NSMakeRect(10, 10, 30, 30)];
                }
            });
        }

        /* Benchmark 4: Display cycle (flush pending invalidations) */
        if (json) {
            BENCH_JSON("view_display_cycle", ITERATIONS / 10, {
                for (int j = 0; j < VIEW_COUNT; j += 4) {
                    [[views objectAtIndex:(NSUInteger)j] setNeedsDisplay:YES];
                }
                [contentView displayIfNeeded];
            });
        } else {
            BENCH("view_display_cycle", ITERATIONS / 10, {
                for (int j = 0; j < VIEW_COUNT; j += 4) {
                    [[views objectAtIndex:(NSUInteger)j] setNeedsDisplay:YES];
                }
                [contentView displayIfNeeded];
            });
        }

        [window release];
    }

    return 0;
}
