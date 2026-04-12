/*
 * test_rethrow_uaf.m - RB-1: Exception rethrow use-after-free
 *
 * Validates that rethrowing an exception from an inner @catch does not
 * cause a use-after-free or crash.  The exception's name and reason
 * must be preserved after rethrow.
 *
 * Bug: The runtime may free the exception object during unwind before
 * the outer catch can access it, leading to UAF.
 *
 * Expected AFTER fix: All assertions pass, no crash.
 * Expected BEFORE fix: Crash (SIGSEGV/SIGBUS) or corrupted data.
 */

#import <Foundation/Foundation.h>
#include "../../common/test_utils.h"

int main(void) {
    @autoreleasepool {
        printf("=== RB-1: Exception Rethrow UAF Test ===\n\n");

        NSString *expectedName   = @"TestException";
        NSString *expectedReason = @"Testing rethrow safety";
        BOOL innerCatchReached   = NO;
        BOOL outerCatchReached   = NO;

        /* Test 1: Basic rethrow preserves exception identity */
        @try {
            @try {
                @throw [NSException exceptionWithName:expectedName
                                               reason:expectedReason
                                             userInfo:nil];
            } @catch (NSException *inner) {
                innerCatchReached = YES;
                TEST_ASSERT([inner.name isEqualToString:expectedName],
                            "inner catch: exception name matches");
                TEST_ASSERT([inner.reason isEqualToString:expectedReason],
                            "inner catch: exception reason matches");
                @throw;  /* rethrow */
            }
        } @catch (NSException *outer) {
            outerCatchReached = YES;
            TEST_ASSERT([outer.name isEqualToString:expectedName],
                        "outer catch: exception name preserved after rethrow");
            TEST_ASSERT([outer.reason isEqualToString:expectedReason],
                        "outer catch: exception reason preserved after rethrow");
        }

        TEST_ASSERT(innerCatchReached, "inner @catch was reached");
        TEST_ASSERT(outerCatchReached, "outer @catch was reached after rethrow");

        /* Test 2: Multiple rethrows through nested handlers */
        BOOL level1 = NO, level2 = NO, level3 = NO;
        @try {
            @try {
                @try {
                    @throw [NSException exceptionWithName:@"DeepRethrow"
                                                   reason:@"triple nesting"
                                                 userInfo:nil];
                } @catch (NSException *e) {
                    level1 = YES;
                    @throw;
                }
            } @catch (NSException *e) {
                level2 = YES;
                TEST_ASSERT([e.name isEqualToString:@"DeepRethrow"],
                            "level 2: name intact after first rethrow");
                @throw;
            }
        } @catch (NSException *e) {
            level3 = YES;
            TEST_ASSERT([e.name isEqualToString:@"DeepRethrow"],
                        "level 3: name intact after second rethrow");
            TEST_ASSERT([e.reason isEqualToString:@"triple nesting"],
                        "level 3: reason intact after second rethrow");
        }

        TEST_ASSERT(level1 && level2 && level3,
                    "all three nesting levels were reached");

        /* Test 3: Rethrow in a loop (stress the unwind path) */
        int rethrowCount = 0;
        for (int i = 0; i < 100; i++) {
            @try {
                @try {
                    @throw [NSException exceptionWithName:@"LoopException"
                                                   reason:@"loop iteration"
                                                 userInfo:nil];
                } @catch (NSException *e) {
                    @throw;
                }
            } @catch (NSException *e) {
                rethrowCount++;
            }
        }
        TEST_ASSERT_EQUAL(rethrowCount, 100,
                          "100 rethrow iterations completed without crash");
    }

    return TEST_SUMMARY();
}
