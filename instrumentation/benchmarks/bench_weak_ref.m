/*
 * bench_weak_ref.m - Weak reference operations benchmark (multi-threaded)
 *
 * Measures weak reference store/load/clear at 1, 2, 4, 8 threads.
 * Exercises the weak reference side table and its locking.
 *
 * Targets: PF-6 (weak ref lock striping, expect 5-8x improvement)
 *
 * Usage: ./bench_weak_ref [--json]
 */

#import <Foundation/Foundation.h>
#include "bench_harness.h"

#define ITERATIONS_PER_THREAD 1000000

/* Shared object that threads will create weak references to */
static id g_shared_object = nil;

/* Thread function: store/load/clear weak refs in a loop */
static void weak_ref_worker(void *arg, int iterations) {
    (void)arg;
    for (int i = 0; i < iterations; i++) {
        @autoreleasepool {
            __weak id weakRef = g_shared_object;
            id strong = weakRef;  /* load the weak ref */
            (void)strong;
            weakRef = nil;        /* clear the weak ref */
        }
    }
}

/* Thread function: store weak refs only */
static void weak_store_worker(void *arg, int iterations) {
    (void)arg;
    for (int i = 0; i < iterations; i++) {
        __weak id weakRef = g_shared_object;
        (void)weakRef;
    }
}

/* Thread function: load weak refs only */
static void weak_load_worker(void *arg, int iterations) {
    (void)arg;
    __weak id weakRef = g_shared_object;
    for (int i = 0; i < iterations; i++) {
        id strong = weakRef;
        (void)strong;
    }
}

int main(int argc, char *argv[]) {
    int json = (argc > 1 && strcmp(argv[1], "--json") == 0);

    @autoreleasepool {
        g_shared_object = [[NSObject alloc] init];
        int thread_counts[] = {1, 2, 4, 8};
        int num_configs = 4;

        for (int t = 0; t < num_configs; t++) {
            int threads = thread_counts[t];
            char name[64];

            /* Full cycle: store + load + clear */
            snprintf(name, sizeof(name), "weak_ref_cycle_%dt", threads);
            if (json) {
                /* For JSON, use single-threaded BENCH_JSON per thread count
                   since BENCH_THREADED always prints human-readable */
                printf("{\"bench\":\"%s\",\"threads\":%d,\"iterations\":%d}\n",
                       name, threads, ITERATIONS_PER_THREAD);
            }
            BENCH_THREADED(name, threads, ITERATIONS_PER_THREAD,
                           weak_ref_worker, NULL);

            /* Store only */
            snprintf(name, sizeof(name), "weak_ref_store_%dt", threads);
            if (json) {
                printf("{\"bench\":\"%s\",\"threads\":%d,\"iterations\":%d}\n",
                       name, threads, ITERATIONS_PER_THREAD);
            }
            BENCH_THREADED(name, threads, ITERATIONS_PER_THREAD,
                           weak_store_worker, NULL);

            /* Load only */
            snprintf(name, sizeof(name), "weak_ref_load_%dt", threads);
            if (json) {
                printf("{\"bench\":\"%s\",\"threads\":%d,\"iterations\":%d}\n",
                       name, threads, ITERATIONS_PER_THREAD);
            }
            BENCH_THREADED(name, threads, ITERATIONS_PER_THREAD,
                           weak_load_worker, NULL);
        }

        [g_shared_object release];
        g_shared_object = nil;
    }

    return 0;
}
