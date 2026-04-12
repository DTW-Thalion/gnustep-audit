/*
 * test_path_nan.m - AR-O1: NaN coordinates in CGPath
 *
 * Adds NaN coordinates to a CGPath and checks that the bounding box
 * computation does not produce corrupted results.
 *
 * Bug: CGPathGetBoundingBox uses simple < > comparisons which always
 * return false for NaN. A NaN coordinate that arrives first (i == 0)
 * sets minX/minY/maxX/maxY to NaN, then all subsequent comparisons
 * fail, corrupting the entire bounding box.
 *
 * Expected AFTER fix: NaN coordinates gracefully handled (ignored or error).
 * Expected BEFORE fix: Bounding box corrupted (contains NaN).
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <stdio.h>
#include "../../common/test_utils.h"

int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    printf("=== AR-O1: CGPath NaN Coordinates Test ===\n\n");

    /* Test 1: Normal path bounding box (baseline) */
    CGMutablePathRef normalPath = CGPathCreateMutable();
    TEST_ASSERT_NOT_NULL(normalPath, "CGPathCreateMutable succeeded");

    CGPathMoveToPoint(normalPath, NULL, 10.0, 20.0);
    CGPathAddLineToPoint(normalPath, NULL, 50.0, 60.0);

    CGRect normalBox = CGPathGetBoundingBox(normalPath);
    printf("  Normal path bbox: (%.1f, %.1f, %.1f, %.1f)\n",
           normalBox.origin.x, normalBox.origin.y,
           normalBox.size.width, normalBox.size.height);
    TEST_ASSERT(!isnan(normalBox.origin.x), "Normal path bbox.x is not NaN");
    TEST_ASSERT(!isnan(normalBox.origin.y), "Normal path bbox.y is not NaN");
    TEST_ASSERT(!isnan(normalBox.size.width), "Normal path bbox.width is not NaN");
    TEST_ASSERT(!isnan(normalBox.size.height), "Normal path bbox.height is not NaN");

    CGPathRelease(normalPath);

    /* Test 2: Path starting with NaN coordinates */
    printf("\nTesting path with NaN as first coordinate...\n");
    CGMutablePathRef nanPath = CGPathCreateMutable();
    TEST_ASSERT_NOT_NULL(nanPath, "CGPathCreateMutable succeeded for NaN test");

    CGPathMoveToPoint(nanPath, NULL, NAN, NAN);
    CGPathAddLineToPoint(nanPath, NULL, 10.0, 20.0);
    CGPathAddLineToPoint(nanPath, NULL, 30.0, 40.0);

    CGRect nanBox = CGPathGetBoundingBox(nanPath);
    printf("  NaN-first path bbox: (%.1f, %.1f, %.1f, %.1f)\n",
           nanBox.origin.x, nanBox.origin.y,
           nanBox.size.width, nanBox.size.height);

    /* After fix, NaN should be excluded and bbox should reflect only valid points */
    TEST_ASSERT(!isnan(nanBox.origin.x),
                "Bounding box X not corrupted by NaN");
    TEST_ASSERT(!isnan(nanBox.origin.y),
                "Bounding box Y not corrupted by NaN");
    TEST_ASSERT(!isnan(nanBox.size.width),
                "Bounding box width not corrupted by NaN");
    TEST_ASSERT(!isnan(nanBox.size.height),
                "Bounding box height not corrupted by NaN");

    CGPathRelease(nanPath);

    /* Test 3: Path with NaN in the middle */
    printf("\nTesting path with NaN in the middle...\n");
    CGMutablePathRef midNanPath = CGPathCreateMutable();
    CGPathMoveToPoint(midNanPath, NULL, 5.0, 5.0);
    CGPathAddLineToPoint(midNanPath, NULL, NAN, NAN);
    CGPathAddLineToPoint(midNanPath, NULL, 15.0, 15.0);

    CGRect midBox = CGPathGetBoundingBox(midNanPath);
    printf("  Mid-NaN path bbox: (%.1f, %.1f, %.1f, %.1f)\n",
           midBox.origin.x, midBox.origin.y,
           midBox.size.width, midBox.size.height);
    TEST_ASSERT(!isnan(midBox.origin.x),
                "Mid-NaN bbox X not corrupted");
    TEST_ASSERT(!isnan(midBox.size.width),
                "Mid-NaN bbox width not corrupted");

    CGPathRelease(midNanPath);

    /* Test 4: Path with infinity */
    printf("\nTesting path with INFINITY coordinate...\n");
    CGMutablePathRef infPath = CGPathCreateMutable();
    CGPathMoveToPoint(infPath, NULL, 0.0, 0.0);
    CGPathAddLineToPoint(infPath, NULL, INFINITY, 10.0);

    CGRect infBox = CGPathGetBoundingBox(infPath);
    printf("  Inf path bbox: (%.1f, %.1f, %.1f, %.1f)\n",
           infBox.origin.x, infBox.origin.y,
           infBox.size.width, infBox.size.height);
    TEST_ASSERT(!isnan(infBox.origin.x),
                "Infinity path bbox X not NaN");

    CGPathRelease(infPath);

    [pool release];
    return TEST_SUMMARY();
}
