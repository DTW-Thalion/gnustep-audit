/*
 * test_gstate_underflow.m - AR-O3: GState stack underflow
 *
 * Calls CGContextRestoreGState more times than CGContextSaveGState
 * and then attempts to draw, verifying the context handles this
 * gracefully.
 *
 * Bug: CGContextRestoreGState pops the ct_additions linked list without
 * checking whether it has hit the bottom of the stack. After underflow,
 * ctx->add becomes NULL. The next draw operation dereferences ctx->add,
 * causing a NULL pointer crash.
 *
 * Expected AFTER fix: Error or assertion on underflow; no crash on draw.
 * Expected BEFORE fix: NULL deref crash on subsequent draw operation.
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include "../../common/test_utils.h"

int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    printf("=== AR-O3: GState Stack Underflow Test ===\n\n");

    /* Create a bitmap context */
    size_t width = 32;
    size_t height = 32;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    TEST_ASSERT_NOT_NULL(colorSpace, "CGColorSpaceCreateDeviceRGB succeeded");

    CGContextRef ctx = CGBitmapContextCreate(
        NULL, width, height, 8, width * 4,
        colorSpace, kCGImageAlphaPremultipliedLast);
    TEST_ASSERT_NOT_NULL(ctx, "CGBitmapContextCreate succeeded");

    if (ctx) {
        /* Do one save/restore pair (balanced) */
        printf("Performing balanced save/restore...\n");
        CGContextSaveGState(ctx);
        CGContextRestoreGState(ctx);
        TEST_ASSERT(1, "Balanced save/restore succeeded");

        /* Now restore WITHOUT a matching save - this underflows the stack.
         * The code sets ctx->add = ctx->add->next, but when we're at the
         * bottom, next is NULL. */
        printf("Performing unbalanced restore (underflow)...\n");
        CGContextRestoreGState(ctx);
        TEST_ASSERT(1, "First unbalanced RestoreGState did not crash");

        /* Try to restore again - even deeper underflow */
        printf("Performing second unbalanced restore...\n");
        CGContextRestoreGState(ctx);
        TEST_ASSERT(1, "Second unbalanced RestoreGState did not crash");

        /* Now try to draw. Before the fix, ctx->add is NULL here,
         * so accessing ctx->add->fill_cp crashes. */
        printf("Attempting to draw after underflow...\n");
        CGContextSetRGBFillColor(ctx, 1.0, 0.0, 0.0, 1.0);
        TEST_ASSERT(1, "SetRGBFillColor after underflow did not crash");

        CGContextFillRect(ctx, CGRectMake(0, 0, width, height));
        TEST_ASSERT(1, "FillRect after underflow did not crash");

        /* Verify we can still save/restore after the underflow */
        printf("Testing save/restore recovery after underflow...\n");
        CGContextSaveGState(ctx);
        TEST_ASSERT(1, "SaveGState after underflow did not crash");

        CGContextRestoreGState(ctx);
        TEST_ASSERT(1, "RestoreGState after recovery did not crash");

        CGContextRelease(ctx);
    }

    CGColorSpaceRelease(colorSpace);

    [pool release];
    return TEST_SUMMARY();
}
