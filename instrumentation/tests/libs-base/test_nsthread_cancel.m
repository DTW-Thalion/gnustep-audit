/*
 * test_nsthread_cancel.m - TS-6: NSThread cross-thread cancellation
 *
 * Cancel an NSThread from another thread. Verify isCancelled returns YES
 * from the target thread.
 */
#import <Foundation/Foundation.h>
#include "../../common/test_utils.h"
#include <pthread.h>

@interface WorkerThread : NSObject
@property (atomic) BOOL sawCancellation;
@property (atomic) BOOL started;
@property (atomic) BOOL finished;
@end

@implementation WorkerThread

- (void)threadMain:(id)arg {
    (void)arg;

    @autoreleasepool {
        self.started = YES;

        NSThread *current = [NSThread currentThread];

        /*
         * Spin waiting for cancellation. In a real scenario, the thread
         * would be doing work and periodically checking isCancelled.
         */
        int iterations = 0;
        while (![current isCancelled] && iterations < 5000) {
            [NSThread sleepForTimeInterval:0.001]; /* 1ms */
            iterations++;
        }

        self.sawCancellation = [current isCancelled];
        self.finished = YES;

        if (self.sawCancellation) {
            printf("  Worker thread saw cancellation after %d iterations\n",
                   iterations);
        } else {
            printf("  Worker thread timed out waiting for cancellation\n");
        }
    }
}

@end

int main(void) {
    @autoreleasepool {
        printf("=== test_nsthread_cancel (TS-6) ===\n");

        WorkerThread *worker = [[WorkerThread alloc] init];

        /* Start the worker thread */
        NSThread *thread = [[NSThread alloc]
            initWithTarget:worker
                  selector:@selector(threadMain:)
                    object:nil];
        [thread start];

        /* Wait for the thread to actually start */
        int waitCount = 0;
        while (!worker.started && waitCount < 1000) {
            [NSThread sleepForTimeInterval:0.001];
            waitCount++;
        }
        TEST_ASSERT(worker.started, "Worker thread started");

        /* Verify thread is not cancelled initially */
        TEST_ASSERT(![thread isCancelled],
                    "Thread should not be cancelled initially");

        /* Cancel the thread from the main thread */
        printf("  Cancelling worker thread from main thread...\n");
        [thread cancel];

        /* Verify isCancelled returns YES immediately from calling thread */
        TEST_ASSERT([thread isCancelled],
                    "isCancelled should return YES after cancel");

        /* Wait for the worker to notice the cancellation */
        waitCount = 0;
        while (!worker.finished && waitCount < 5000) {
            [NSThread sleepForTimeInterval:0.001];
            waitCount++;
        }

        TEST_ASSERT(worker.finished, "Worker thread should finish");
        TEST_ASSERT(worker.sawCancellation,
                    "Worker thread should see isCancelled == YES");

        /*
         * Test multiple cancellations don't cause issues.
         * Calling cancel multiple times should be safe.
         */
        [thread cancel];
        [thread cancel];
        TEST_ASSERT([thread isCancelled],
                    "Multiple cancel calls should be safe");

        /*
         * Test that cancellation flag is visible across threads quickly.
         * We already verified this above, but let's also test with a
         * second thread that checks the flag.
         */
        __block BOOL secondThreadSawCancel = NO;
        NSThread *checker = [[NSThread alloc]
            initWithBlock:^{
                secondThreadSawCancel = [thread isCancelled];
            }];
        [checker start];

        /* Wait for checker to complete */
        waitCount = 0;
        while (![checker isFinished] && waitCount < 1000) {
            [NSThread sleepForTimeInterval:0.001];
            waitCount++;
        }

        TEST_ASSERT(secondThreadSawCancel,
                    "Cancellation flag visible from third thread");

        printf("  Thread cancellation working correctly.\n");

        return TEST_SUMMARY();
    }
}
