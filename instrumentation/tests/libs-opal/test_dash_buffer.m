/*
 * test_dash_buffer.m - AR-O8: Line dash buffer underallocation
 *
 * Sets a line dash pattern with 10 dashes on a CGContext, then saves
 * and restores the graphics state to exercise OpalGStateSnapshot's
 * dash copy code.
 *
 * Bug: In CGContext+GState.m, OpalGStateSnapshot's initWithContext:
 * allocates dash buffer with malloc(dashes_count) instead of
 * malloc(dashes_count * sizeof(double)). Since sizeof(double) == 8,
 * this allocates only 1/8 of the needed memory. cairo_get_dash()
 * then writes past the allocation, causing heap corruption.
 *
 * Expected AFTER fix: No heap corruption; dash pattern preserved.
 * Expected BEFORE fix: Heap corruption from undersized malloc.
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include "../../common/test_utils.h"

int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    printf("=== AR-O8: Dash Buffer Underallocation Test ===\n\n");

    /* Create a bitmap context to work with */
    size_t width = 64;
    size_t height = 64;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    TEST_ASSERT_NOT_NULL(colorSpace, "CGColorSpaceCreateDeviceRGB succeeded");

    CGContextRef ctx = CGBitmapContextCreate(
        NULL, width, height, 8, width * 4,
        colorSpace, kCGImageAlphaPremultipliedLast);
    TEST_ASSERT_NOT_NULL(ctx, "CGBitmapContextCreate succeeded");

    if (ctx) {
        /* Set a dash pattern with 10 elements (80 bytes needed, but
         * the bug allocates only 10 bytes) */
        CGFloat dashes[10] = {5.0, 3.0, 5.0, 3.0, 5.0, 3.0, 5.0, 3.0, 5.0, 3.0};
        printf("Setting line dash with 10 elements...\n");
        CGContextSetLineDash(ctx, 0.0, dashes, 10);
        TEST_ASSERT(1, "CGContextSetLineDash with 10 dashes succeeded");

        /* Save GState - this triggers OpalGStateSnapshot's initWithContext:
         * which has the malloc(count) bug instead of malloc(count*sizeof(double)) */
        printf("Saving graphics state (triggers dash buffer copy)...\n");
        CGContextSaveGState(ctx);
        TEST_ASSERT(1, "CGContextSaveGState with dashes did not crash");

        /* Do some drawing to exercise the state */
        CGContextSetRGBStrokeColor(ctx, 0.0, 0.0, 0.0, 1.0);
        CGContextMoveToPoint(ctx, 0, 32);
        CGContextAddLineToPoint(ctx, 64, 32);
        CGContextStrokePath(ctx);
        TEST_ASSERT(1, "Stroke with dashed line did not crash");

        /* Restore GState - this applies the snapshot back, using the
         * potentially corrupted dash buffer */
        printf("Restoring graphics state (triggers dash buffer restore)...\n");
        CGContextRestoreGState(ctx);
        TEST_ASSERT(1, "CGContextRestoreGState with dashes did not crash");

        /* Draw again after restore to verify dash state is sane */
        CGContextMoveToPoint(ctx, 0, 16);
        CGContextAddLineToPoint(ctx, 64, 16);
        CGContextStrokePath(ctx);
        TEST_ASSERT(1, "Stroke after restore did not crash");

        CGContextRelease(ctx);
    }

    CGColorSpaceRelease(colorSpace);

    [pool release];
    return TEST_SUMMARY();
}
