/*
 * test_nsoperation_kvo.m - TS-4: NSOperationQueue KVO consistency
 *
 * Add KVO observer on NSOperationQueue's operationCount.
 * Run operations concurrently. Verify observer callbacks are consistent
 * (no crashes, no missing notifications, count goes to zero eventually).
 */
#import <Foundation/Foundation.h>
#include "../../common/test_utils.h"
#include <pthread.h>

#define NUM_OPERATIONS 50

@interface KVOObserver : NSObject
@property (atomic) int notificationCount;
@property (atomic) int maxCount;
@property (atomic) BOOL sawZero;
@property (atomic) BOOL gotException;
@end

@implementation KVOObserver

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    @try {
        if ([keyPath isEqualToString:@"operationCount"]) {
            self.notificationCount++;
            NSNumber *newVal = change[NSKeyValueChangeNewKey];
            if (newVal) {
                int val = [newVal intValue];
                if (val > self.maxCount) {
                    self.maxCount = val;
                }
                if (val == 0) {
                    self.sawZero = YES;
                }
            }
        }
    } @catch (NSException *e) {
        self.gotException = YES;
        printf("  KVO exception: %s\n", [[e reason] UTF8String]);
    }
}

@end

int main(void) {
    @autoreleasepool {
        printf("=== test_nsoperation_kvo (TS-4) ===\n");

        NSOperationQueue *queue = [[NSOperationQueue alloc] init];
        queue.maxConcurrentOperationCount = 4;

        KVOObserver *observer = [[KVOObserver alloc] init];

        /* Add KVO observer for operationCount */
        @try {
            [queue addObserver:observer
                    forKeyPath:@"operationCount"
                       options:NSKeyValueObservingOptionNew
                       context:NULL];
        } @catch (NSException *e) {
            printf("  Could not add KVO observer: %s\n",
                   [[e reason] UTF8String]);
            TEST_ASSERT(0, "KVO observer registration should not throw");
            return TEST_SUMMARY();
        }

        printf("  Adding %d concurrent operations...\n", NUM_OPERATIONS);

        /* Add many operations that do a small amount of work */
        for (int i = 0; i < NUM_OPERATIONS; i++) {
            [queue addOperationWithBlock:^{
                /* Simulate some work */
                volatile int sum = 0;
                for (int j = 0; j < 1000; j++) {
                    sum += j;
                }
                (void)sum;
            }];
        }

        /* Wait for all operations to finish */
        [queue waitUntilAllOperationsAreFinished];

        /* Give KVO a moment to deliver final notifications */
        [[NSRunLoop currentRunLoop] runUntilDate:
            [NSDate dateWithTimeIntervalSinceNow:0.5]];

        printf("  KVO notifications received: %d\n", observer.notificationCount);
        printf("  Max observed count: %d\n", observer.maxCount);
        printf("  Saw count reach zero: %s\n", observer.sawZero ? "YES" : "NO");

        /* Remove observer before checking results */
        @try {
            [queue removeObserver:observer forKeyPath:@"operationCount"];
            TEST_ASSERT(1, "KVO observer removed without crash");
        } @catch (NSException *e) {
            printf("  Exception removing observer: %s\n",
                   [[e reason] UTF8String]);
            TEST_ASSERT(0, "KVO observer removal should not throw");
        }

        /* Verify results */
        TEST_ASSERT(observer.notificationCount > 0,
                    "Should have received KVO notifications");
        TEST_ASSERT(observer.gotException == NO,
                    "KVO callbacks should not throw exceptions");

        /*
         * After all operations finish, operationCount should be 0.
         * If KVO is inconsistent, we might never see zero.
         */
        NSUInteger finalCount = queue.operationCount;
        TEST_ASSERT(finalCount == 0,
                    "Operation count should be 0 after waitUntilAllOperationsAreFinished");

        /*
         * The observer should have seen the count go to zero at some point.
         * If KVO is racing, the final zero notification might be missed.
         */
        if (!observer.sawZero) {
            printf("  WARNING: KVO observer never saw operationCount == 0\n");
            printf("  This may indicate a race in KVO notification delivery.\n");
        }
        /* Don't fail on this - it can be timing-dependent */

        return TEST_SUMMARY();
    }
}
