/*
 * bench_runloop_timers.m - Run loop timer fire latency benchmark
 *
 * Measures how timer count affects run loop iteration cost.
 * Tests with 1, 10, 100, and 1000 timers.
 *
 * Targets: PF-2 (min-heap timer data structure)
 *
 * Usage: ./bench_runloop_timers [--json]
 */

#import <Foundation/Foundation.h>
#include "bench_harness.h"

#define FIRE_ITERS 10000

/* Counter incremented by timer callbacks */
static volatile int g_fire_count = 0;

@interface TimerTarget : NSObject
- (void)timerFired:(NSTimer *)timer;
@end

@implementation TimerTarget
- (void)timerFired:(NSTimer *)timer {
    (void)timer;
    g_fire_count++;
}
@end

static void benchTimerCount(int timerCount, int json_flag) {
    @autoreleasepool {
        TimerTarget *target = [[TimerTarget alloc] init];
        NSRunLoop *loop = [NSRunLoop currentRunLoop];
        NSMutableArray *timers = [NSMutableArray arrayWithCapacity:(NSUInteger)timerCount];

        /* Create timers with very short intervals */
        for (int i = 0; i < timerCount; i++) {
            NSTimer *t = [NSTimer timerWithTimeInterval:0.0001
                                                 target:target
                                               selector:@selector(timerFired:)
                                               userInfo:nil
                                                repeats:YES];
            [loop addTimer:t forMode:NSDefaultRunLoopMode];
            [timers addObject:t];
        }

        char name[64];
        snprintf(name, sizeof(name), "runloop_%d_timers", timerCount);

        g_fire_count = 0;

        /* Benchmark: run the loop for FIRE_ITERS iterations */
        if (json_flag) {
            BENCH_JSON(name, FIRE_ITERS, {
                [loop runMode:NSDefaultRunLoopMode
                   beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.0001]];
            });
        } else {
            BENCH(name, FIRE_ITERS, {
                [loop runMode:NSDefaultRunLoopMode
                   beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.0001]];
            });
        }

        /* Invalidate all timers */
        for (NSTimer *t in timers) {
            [t invalidate];
        }

        [target release];
    }
}

int main(int argc, char *argv[]) {
    int json = (argc > 1 && strcmp(argv[1], "--json") == 0);

    @autoreleasepool {
        int counts[] = {1, 10, 100, 1000};
        for (int i = 0; i < 4; i++) {
            benchTimerCount(counts[i], json);
        }
    }

    return 0;
}
