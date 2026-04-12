/*
 * bench_msg_send.m - Message dispatch throughput benchmark
 *
 * Measures objc_msgSend fast-path performance by sending a simple
 * message ([obj class]) millions of times.
 *
 * Targets: objc_msgSend fast path optimization
 *
 * Usage: ./bench_msg_send [--json]
 */

#import <Foundation/Foundation.h>
#include "bench_harness.h"

#define ITERATIONS 10000000

@interface BenchTarget : NSObject
- (void)noop;
@end

@implementation BenchTarget
- (void)noop { }
@end

int main(int argc, char *argv[]) {
    int json = (argc > 1 && strcmp(argv[1], "--json") == 0);

    @autoreleasepool {
        id obj = [[BenchTarget alloc] init];

        /* Benchmark 1: [obj class] - very common fast-path message */
        if (json) {
            BENCH_JSON("msg_send_class", ITERATIONS, {
                (void)[obj class];
            });
        } else {
            BENCH("msg_send_class", ITERATIONS, {
                (void)[obj class];
            });
        }

        /* Benchmark 2: [obj noop] - custom method dispatch */
        if (json) {
            BENCH_JSON("msg_send_noop", ITERATIONS, {
                [obj noop];
            });
        } else {
            BENCH("msg_send_noop", ITERATIONS, {
                [obj noop];
            });
        }

        /* Benchmark 3: [obj respondsToSelector:] - selector lookup */
        SEL sel = @selector(noop);
        if (json) {
            BENCH_JSON("msg_send_respondsToSelector", ITERATIONS, {
                (void)[obj respondsToSelector:sel];
            });
        } else {
            BENCH("msg_send_respondsToSelector", ITERATIONS, {
                (void)[obj respondsToSelector:sel];
            });
        }

        /* Benchmark 4: class method dispatch */
        Class cls = [BenchTarget class];
        if (json) {
            BENCH_JSON("msg_send_class_method", ITERATIONS, {
                (void)[cls class];
            });
        } else {
            BENCH("msg_send_class_method", ITERATIONS, {
                (void)[cls class];
            });
        }

        [obj release];
    }

    return 0;
}
