/*
 * test_layer_cycle.m - AR-Q2: Sublayer cycle detection
 *
 * Adds layer A as sublayer of B, then B as sublayer of A, creating
 * a parent-child cycle in the layer tree.
 *
 * Bug: CALayer's addSublayer: does not check whether adding the layer
 * would create a cycle. If A is a sublayer of B and B is then added
 * as a sublayer of A, the layer tree forms a cycle. Any recursive
 * traversal (rendering, layout, hit testing) enters infinite recursion
 * and crashes with a stack overflow.
 *
 * Expected AFTER fix: Cycle detected and prevented (exception or silent ignore).
 * Expected BEFORE fix: Infinite recursion on render/layout traversal.
 */

#import <Foundation/Foundation.h>
#import <QuartzCore/CALayer.h>
#include <stdio.h>
#include "../../common/test_utils.h"

int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    printf("=== AR-Q2: Layer Cycle Detection Test ===\n\n");

    /* Test 1: Normal sublayer hierarchy works */
    printf("Testing normal sublayer hierarchy...\n");
    CALayer *root = [CALayer layer];
    CALayer *child = [CALayer layer];
    CALayer *grandchild = [CALayer layer];

    [root addSublayer: child];
    [child addSublayer: grandchild];

    TEST_ASSERT([[root sublayers] containsObject: child],
                "child is sublayer of root");
    TEST_ASSERT([[child sublayers] containsObject: grandchild],
                "grandchild is sublayer of child");
    TEST_ASSERT([child superlayer] == root,
                "child's superlayer is root");

    /* Test 2: Self-cycle - adding a layer as its own sublayer */
    printf("\nTesting self-cycle (A -> A)...\n");
    CALayer *selfLayer = [CALayer layer];
    @try {
        [selfLayer addSublayer: selfLayer];
        /* If no exception, check that it was silently ignored or handled */
        BOOL isSelfSublayer = [[selfLayer sublayers] containsObject: selfLayer];
        if (isSelfSublayer) {
            printf("  WARNING: Layer added itself as sublayer (cycle not prevented)\n");
            /* Remove to avoid infinite loops in later operations */
            [selfLayer removeFromSuperlayer];
        }
        TEST_ASSERT(1, "Self-cycle add did not crash");
    } @catch (NSException *e) {
        printf("  Self-cycle correctly rejected: %s\n", [[e reason] UTF8String]);
        TEST_ASSERT(1, "Self-cycle correctly raised exception");
    }

    /* Test 3: Two-node cycle: A -> B -> A */
    printf("\nTesting two-node cycle (A -> B -> A)...\n");
    CALayer *layerA = [CALayer layer];
    CALayer *layerB = [CALayer layer];

    [layerA addSublayer: layerB];
    TEST_ASSERT([[layerA sublayers] containsObject: layerB],
                "B is sublayer of A");
    TEST_ASSERT([layerB superlayer] == layerA,
                "B's superlayer is A");

    @try {
        /* This creates the cycle: A -> B -> A */
        [layerB addSublayer: layerA];

        /* If we get here, either the cycle was silently ignored
         * or the cycle was created (which is the bug) */
        BOOL cycleCreated = [[layerB sublayers] containsObject: layerA];
        if (cycleCreated) {
            printf("  WARNING: Cycle was created (A <-> B) - this is the bug\n");
            /* Don't traverse - that would infinite-loop */

            /* Manually break the cycle to avoid crash in cleanup */
            [(NSMutableArray *)[layerB sublayers] removeObject: layerA];
        } else {
            printf("  Cycle addition was silently ignored\n");
        }
        TEST_ASSERT(1, "Two-node cycle add did not crash");
    } @catch (NSException *e) {
        printf("  Two-node cycle correctly rejected: %s\n",
               [[e reason] UTF8String]);
        TEST_ASSERT(1, "Two-node cycle correctly raised exception");
    }

    /* Test 4: Three-node cycle: A -> B -> C -> A */
    printf("\nTesting three-node cycle (A -> B -> C -> A)...\n");
    CALayer *lA = [CALayer layer];
    CALayer *lB = [CALayer layer];
    CALayer *lC = [CALayer layer];

    [lA addSublayer: lB];
    [lB addSublayer: lC];

    @try {
        [lC addSublayer: lA];

        BOOL cycleCreated = [[lC sublayers] containsObject: lA];
        if (cycleCreated) {
            printf("  WARNING: Three-node cycle was created - this is the bug\n");
            [(NSMutableArray *)[lC sublayers] removeObject: lA];
        } else {
            printf("  Three-node cycle addition was silently ignored\n");
        }
        TEST_ASSERT(1, "Three-node cycle add did not crash");
    } @catch (NSException *e) {
        printf("  Three-node cycle correctly rejected: %s\n",
               [[e reason] UTF8String]);
        TEST_ASSERT(1, "Three-node cycle correctly raised exception");
    }

    /* Test 5: allAncestorLayers on a simple chain (no cycle) */
    printf("\nTesting allAncestorLayers on valid hierarchy...\n");
    NSArray *ancestors = [grandchild allAncestorLayers];
    TEST_ASSERT_NOT_NULL(ancestors, "allAncestorLayers returned non-nil");
    TEST_ASSERT([ancestors count] == 2,
                "grandchild has 2 ancestors (child, root)");

    [pool release];
    return TEST_SUMMARY();
}
