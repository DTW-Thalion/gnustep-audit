/*
 * bench_harness.c - Threaded benchmark runner implementation
 *
 * Implements bench_run_threaded(): spawns pthreads, times total execution,
 * reports per-thread and aggregate ops/sec.
 *
 * Plain C only - no Objective-C, no blocks. Uses function pointers.
 * Compile: gcc -c bench_harness.c -lpthread
 */

#include "bench_harness.h"
#include <pthread.h>

/* Per-thread context passed to the pthread start routine */
typedef struct {
    bench_thread_func func;
    void             *arg;
    int               iterations;
    double            elapsed_ns;   /* filled in by thread */
} bench_thread_ctx;

static void *bench_thread_entry(void *raw) {
    bench_thread_ctx *ctx = (bench_thread_ctx *)raw;
    double start = bench_time_ns();
    ctx->func(ctx->arg, ctx->iterations);
    double end = bench_time_ns();
    ctx->elapsed_ns = end - start;
    return NULL;
}

void bench_run_threaded(const char *name, int num_threads,
                        int iterations_per_thread,
                        bench_thread_func func, void *arg) {
    pthread_t        *threads = (pthread_t *)malloc(
                                    sizeof(pthread_t) * (size_t)num_threads);
    bench_thread_ctx *ctxs    = (bench_thread_ctx *)malloc(
                                    sizeof(bench_thread_ctx) * (size_t)num_threads);

    if (!threads || !ctxs) {
        fprintf(stderr, "BENCH_THREADED %s: allocation failed\n", name);
        free(threads);
        free(ctxs);
        return;
    }

    /* Initialize contexts */
    for (int i = 0; i < num_threads; i++) {
        ctxs[i].func       = func;
        ctxs[i].arg        = arg;
        ctxs[i].iterations = iterations_per_thread;
        ctxs[i].elapsed_ns = 0.0;
    }

    /* Time the whole run */
    double wall_start = bench_time_ns();

    for (int i = 0; i < num_threads; i++) {
        if (pthread_create(&threads[i], NULL, bench_thread_entry, &ctxs[i]) != 0) {
            fprintf(stderr, "BENCH_THREADED %s: pthread_create failed for thread %d\n",
                    name, i);
            /* Join whatever we already started */
            for (int j = 0; j < i; j++) {
                pthread_join(threads[j], NULL);
            }
            free(threads);
            free(ctxs);
            return;
        }
    }

    for (int i = 0; i < num_threads; i++) {
        pthread_join(threads[i], NULL);
    }

    double wall_end = bench_time_ns();
    double wall_elapsed_ns = wall_end - wall_start;

    /* Report per-thread stats */
    for (int i = 0; i < num_threads; i++) {
        double ns_per_op = ctxs[i].elapsed_ns / (double)iterations_per_thread;
        double ops_sec   = 1e9 / ns_per_op;
        printf("  thread[%d] %12.1f ns/op  %12.0f ops/sec\n",
               i, ns_per_op, ops_sec);
    }

    /* Aggregate stats */
    int    total_ops      = num_threads * iterations_per_thread;
    double agg_ns_per_op  = wall_elapsed_ns / (double)total_ops;
    double agg_ops_sec    = 1e9 / agg_ns_per_op;

    printf("BENCH_THREADED %-32s %d threads x %d ops  "
           "wall: %.1f ms  %12.1f ns/op  %12.0f ops/sec (aggregate)\n",
           name, num_threads, iterations_per_thread,
           wall_elapsed_ns / 1e6, agg_ns_per_op, agg_ops_sec);

    free(threads);
    free(ctxs);
}
