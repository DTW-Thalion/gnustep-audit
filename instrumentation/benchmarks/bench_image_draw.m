/*
 * bench_image_draw.m - NSImage drawing throughput benchmark
 *
 * Measures composites/sec for NSImage at various sizes.
 * Tests small (32x32), medium (256x256), and large (1024x1024) images.
 *
 * Targets: DPSimage pixel conversion caching
 *
 * Usage: ./bench_image_draw [--json]
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include "bench_harness.h"

#define ITERS_SMALL   50000
#define ITERS_MEDIUM  10000
#define ITERS_LARGE   1000

static NSImage *createTestImage(int width, int height) {
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(width, height)];
    [image lockFocus];
    /* Fill with a gradient-like pattern */
    for (int y = 0; y < height; y += 16) {
        for (int x = 0; x < width; x += 16) {
            float r = (float)x / (float)width;
            float g = (float)y / (float)height;
            [[NSColor colorWithCalibratedRed:r green:g blue:0.5 alpha:1.0] set];
            NSRectFill(NSMakeRect(x, y, 16, 16));
        }
    }
    [image unlockFocus];
    return image;
}

int main(int argc, char *argv[]) {
    int json = (argc > 1 && strcmp(argv[1], "--json") == 0);

    @autoreleasepool {
        [NSApplication sharedApplication];

        /* Create an offscreen window for drawing context */
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 1200, 1200)
                      styleMask:NSWindowStyleMaskTitled
                        backing:NSBackingStoreBuffered
                          defer:YES];
        NSView *view = [window contentView];

        /* Create test images */
        NSImage *small  = createTestImage(32, 32);
        NSImage *medium = createTestImage(256, 256);
        NSImage *large  = createTestImage(1024, 1024);

        NSPoint origin = NSMakePoint(0, 0);

        /* Benchmark 1: Draw 32x32 image */
        if (json) {
            BENCH_JSON("image_draw_32x32", ITERS_SMALL, {
                [view lockFocus];
                [small drawAtPoint:origin
                          fromRect:NSZeroRect
                         operation:NSCompositingOperationSourceOver
                          fraction:1.0];
                [view unlockFocus];
            });
        } else {
            BENCH("image_draw_32x32", ITERS_SMALL, {
                [view lockFocus];
                [small drawAtPoint:origin
                          fromRect:NSZeroRect
                         operation:NSCompositingOperationSourceOver
                          fraction:1.0];
                [view unlockFocus];
            });
        }

        /* Benchmark 2: Draw 256x256 image */
        if (json) {
            BENCH_JSON("image_draw_256x256", ITERS_MEDIUM, {
                [view lockFocus];
                [medium drawAtPoint:origin
                           fromRect:NSZeroRect
                          operation:NSCompositingOperationSourceOver
                           fraction:1.0];
                [view unlockFocus];
            });
        } else {
            BENCH("image_draw_256x256", ITERS_MEDIUM, {
                [view lockFocus];
                [medium drawAtPoint:origin
                           fromRect:NSZeroRect
                          operation:NSCompositingOperationSourceOver
                           fraction:1.0];
                [view unlockFocus];
            });
        }

        /* Benchmark 3: Draw 1024x1024 image */
        if (json) {
            BENCH_JSON("image_draw_1024x1024", ITERS_LARGE, {
                [view lockFocus];
                [large drawAtPoint:origin
                          fromRect:NSZeroRect
                         operation:NSCompositingOperationSourceOver
                          fraction:1.0];
                [view unlockFocus];
            });
        } else {
            BENCH("image_draw_1024x1024", ITERS_LARGE, {
                [view lockFocus];
                [large drawAtPoint:origin
                          fromRect:NSZeroRect
                         operation:NSCompositingOperationSourceOver
                          fraction:1.0];
                [view unlockFocus];
            });
        }

        /* Benchmark 4: Draw with scaling (256->128) */
        NSRect dstRect = NSMakeRect(0, 0, 128, 128);
        NSRect srcRect = NSMakeRect(0, 0, 256, 256);
        if (json) {
            BENCH_JSON("image_draw_scaled", ITERS_MEDIUM, {
                [view lockFocus];
                [medium drawInRect:dstRect
                          fromRect:srcRect
                         operation:NSCompositingOperationSourceOver
                          fraction:1.0];
                [view unlockFocus];
            });
        } else {
            BENCH("image_draw_scaled", ITERS_MEDIUM, {
                [view lockFocus];
                [medium drawInRect:dstRect
                          fromRect:srcRect
                         operation:NSCompositingOperationSourceOver
                          fraction:1.0];
                [view unlockFocus];
            });
        }

        [small release];
        [medium release];
        [large release];
        [window release];
    }

    return 0;
}
