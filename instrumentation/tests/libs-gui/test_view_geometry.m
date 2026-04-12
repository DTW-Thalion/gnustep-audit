/*
 * test_view_geometry.m - RB-G1: Rotated NSView setFrameSize: with zero width
 *
 * Creates a rotated NSView and calls setFrameSize: with zero width.
 * In a rotated coordinate system, zero dimensions can cause division
 * by zero when computing the inverse rotation matrix, leading to NaN
 * propagation through the view geometry.
 *
 * Expected AFTER fix:  No NaN values in frame/bounds; geometry is clamped
 *                      or handled gracefully.
 * Expected BEFORE fix: NaN propagation in frame origin/size, corrupting
 *                      the view hierarchy layout.
 */

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <math.h>
#include "../../common/test_utils.h"

static int is_nan_rect(NSRect r)
{
    return (isnan(r.origin.x) || isnan(r.origin.y) ||
            isnan(r.size.width) || isnan(r.size.height));
}

static int is_inf_rect(NSRect r)
{
    return (isinf(r.origin.x) || isinf(r.origin.y) ||
            isinf(r.size.width) || isinf(r.size.height));
}

int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [NSAutoreleasePool new];

    printf("=== RB-G1: Rotated View Geometry Test ===\n\n");

    [NSApplication sharedApplication];

    /* Create a view and rotate it 45 degrees */
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(50, 50, 100, 100)];
    TEST_ASSERT_NOT_NULL(view, "view created");

    [view setBoundsRotation:45.0];

    NSRect frameBefore = [view frame];
    printf("  Frame before: (%.1f, %.1f, %.1f, %.1f)\n",
           frameBefore.origin.x, frameBefore.origin.y,
           frameBefore.size.width, frameBefore.size.height);

    TEST_ASSERT(!is_nan_rect(frameBefore), "frame is valid before resize");

    /* Set frame size to zero width -- this is the trigger */
    @try {
        [view setFrameSize:NSMakeSize(0, 100)];
    } @catch (NSException *e) {
        printf("  Exception on setFrameSize(0,100): %s\n",
               [[e reason] UTF8String]);
    }

    NSRect frameAfterZeroW = [view frame];
    NSRect boundsAfterZeroW = [view bounds];

    printf("  Frame after setFrameSize(0,100): (%.1f, %.1f, %.1f, %.1f)\n",
           frameAfterZeroW.origin.x, frameAfterZeroW.origin.y,
           frameAfterZeroW.size.width, frameAfterZeroW.size.height);
    printf("  Bounds after setFrameSize(0,100): (%.1f, %.1f, %.1f, %.1f)\n",
           boundsAfterZeroW.origin.x, boundsAfterZeroW.origin.y,
           boundsAfterZeroW.size.width, boundsAfterZeroW.size.height);

    TEST_ASSERT(!is_nan_rect(frameAfterZeroW),
                "frame has no NaN after zero-width resize");
    TEST_ASSERT(!is_inf_rect(frameAfterZeroW),
                "frame has no Inf after zero-width resize");
    TEST_ASSERT(!is_nan_rect(boundsAfterZeroW),
                "bounds has no NaN after zero-width resize");
    TEST_ASSERT(!is_inf_rect(boundsAfterZeroW),
                "bounds has no Inf after zero-width resize");

    /* Also test zero height */
    @try {
        [view setFrameSize:NSMakeSize(100, 0)];
    } @catch (NSException *e) {
        printf("  Exception on setFrameSize(100,0): %s\n",
               [[e reason] UTF8String]);
    }

    NSRect frameAfterZeroH = [view frame];
    NSRect boundsAfterZeroH = [view bounds];

    printf("  Frame after setFrameSize(100,0): (%.1f, %.1f, %.1f, %.1f)\n",
           frameAfterZeroH.origin.x, frameAfterZeroH.origin.y,
           frameAfterZeroH.size.width, frameAfterZeroH.size.height);

    TEST_ASSERT(!is_nan_rect(frameAfterZeroH),
                "frame has no NaN after zero-height resize");
    TEST_ASSERT(!is_inf_rect(frameAfterZeroH),
                "frame has no Inf after zero-height resize");
    TEST_ASSERT(!is_nan_rect(boundsAfterZeroH),
                "bounds has no NaN after zero-height resize");
    TEST_ASSERT(!is_inf_rect(boundsAfterZeroH),
                "bounds has no Inf after zero-height resize");

    /* Test both zero */
    @try {
        [view setFrameSize:NSMakeSize(0, 0)];
    } @catch (NSException *e) {
        printf("  Exception on setFrameSize(0,0): %s\n",
               [[e reason] UTF8String]);
    }

    NSRect frameAfterZeroBoth = [view frame];
    TEST_ASSERT(!is_nan_rect(frameAfterZeroBoth),
                "frame has no NaN after zero-both resize");
    TEST_ASSERT(!is_inf_rect(frameAfterZeroBoth),
                "frame has no Inf after zero-both resize");

    [view release];
    [pool drain];

    return TEST_SUMMARY();
}
