/*
 * test_cgcontext_null.m - AR-O2: NULL CGContext handling
 *
 * Validates that calling CGContextFillPath(NULL) does not crash.
 *
 * Bug: CGContextFillPath and related functions dereference ctx without
 * NULL check. The fill_path() helper accesses ctx->ct and ctx->add,
 * causing a NULL pointer dereference.
 *
 * Expected AFTER fix: No crash; functions return safely (no-op).
 * Expected BEFORE fix: Crash (SIGSEGV) from NULL deref in error logging.
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include "../../common/test_utils.h"

int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    printf("=== AR-O2: CGContext NULL Parameter Test ===\n\n");

    /* Test 1: CGContextFillPath with NULL context */
    printf("Testing CGContextFillPath(NULL)...\n");
    CGContextFillPath(NULL);
    TEST_ASSERT(1, "CGContextFillPath(NULL) did not crash");

    /* Test 2: CGContextStrokePath with NULL context */
    printf("Testing CGContextStrokePath(NULL)...\n");
    CGContextStrokePath(NULL);
    TEST_ASSERT(1, "CGContextStrokePath(NULL) did not crash");

    /* Test 3: CGContextSaveGState with NULL context */
    printf("Testing CGContextSaveGState(NULL)...\n");
    CGContextSaveGState(NULL);
    TEST_ASSERT(1, "CGContextSaveGState(NULL) did not crash");

    /* Test 4: CGContextRestoreGState with NULL context */
    printf("Testing CGContextRestoreGState(NULL)...\n");
    CGContextRestoreGState(NULL);
    TEST_ASSERT(1, "CGContextRestoreGState(NULL) did not crash");

    /* Test 5: CGContextSetLineWidth with NULL context */
    printf("Testing CGContextSetLineWidth(NULL, 1.0)...\n");
    CGContextSetLineWidth(NULL, 1.0);
    TEST_ASSERT(1, "CGContextSetLineWidth(NULL, 1.0) did not crash");

    /* Test 6: CGContextBeginPath with NULL context */
    printf("Testing CGContextBeginPath(NULL)...\n");
    CGContextBeginPath(NULL);
    TEST_ASSERT(1, "CGContextBeginPath(NULL) did not crash");

    [pool release];
    return TEST_SUMMARY();
}
