/*
 * bench_harness.h - Shared benchmark timing infrastructure
 *
 * Cross-platform benchmark harness for GNUstep audit instrumentation.
 * Pure C, no Objective-C dependencies. Header-only macros plus
 * declaration of bench_run_threaded() implemented in bench_harness.c.
 *
 * Supports POSIX (Linux) and Windows (MSYS2/MinGW).
 */
#ifndef BENCH_HARNESS_H
#define BENCH_HARNESS_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/* Cross-platform high-resolution timer                                */
/* ------------------------------------------------------------------ */

#ifdef _WIN32
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  include <windows.h>

static inline double bench_time_ns(void) {
    LARGE_INTEGER freq, counter;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&counter);
    return (double)counter.QuadPart / (double)freq.QuadPart * 1e9;
}

#else /* POSIX */
#  include <time.h>

static inline double bench_time_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1e9 + (double)ts.tv_nsec;
}

#endif /* _WIN32 */

/* ------------------------------------------------------------------ */
/* Forward declaration for threaded benchmark (see bench_harness.c)    */
/* ------------------------------------------------------------------ */

typedef void (*bench_thread_func)(void *arg, int iterations);

void bench_run_threaded(const char *name, int num_threads,
                        int iterations_per_thread,
                        bench_thread_func func, void *arg);

/* ------------------------------------------------------------------ */
/* BENCH — run body for iterations, print ops/sec and ns/op            */
/* ------------------------------------------------------------------ */

#define BENCH(name, iterations, body)                                       \
    do {                                                                    \
        double _bench_start = bench_time_ns();                             \
        for (int _bench_i = 0; _bench_i < (iterations); _bench_i++) {      \
            body;                                                          \
        }                                                                  \
        double _bench_end = bench_time_ns();                               \
        double _bench_elapsed_ns = _bench_end - _bench_start;             \
        double _bench_ns_per_op = _bench_elapsed_ns / (double)(iterations);\
        double _bench_ops_per_sec = 1e9 / _bench_ns_per_op;               \
        printf("BENCH %-40s %10d ops  %12.1f ns/op  %12.0f ops/sec\n",    \
               (name), (iterations), _bench_ns_per_op, _bench_ops_per_sec);\
    } while (0)

/* ------------------------------------------------------------------ */
/* BENCH_JSON — same as BENCH but with JSON output for machine parsing */
/* ------------------------------------------------------------------ */

#define BENCH_JSON(name, iterations, body)                                  \
    do {                                                                    \
        double _bench_start = bench_time_ns();                             \
        for (int _bench_i = 0; _bench_i < (iterations); _bench_i++) {      \
            body;                                                          \
        }                                                                  \
        double _bench_end = bench_time_ns();                               \
        double _bench_elapsed_ns = _bench_end - _bench_start;             \
        double _bench_ns_per_op = _bench_elapsed_ns / (double)(iterations);\
        double _bench_ops_per_sec = 1e9 / _bench_ns_per_op;               \
        printf("{\"bench\":\"%s\",\"iterations\":%d,"                      \
               "\"ns_per_op\":%.1f,\"ops_per_sec\":%.0f}\n",              \
               (name), (iterations), _bench_ns_per_op, _bench_ops_per_sec);\
    } while (0)

/* ------------------------------------------------------------------ */
/* BENCH_THREADED — multi-threaded benchmark using bench_run_threaded   */
/*                                                                     */
/* func_ptr must have signature: void func(void *arg, int iterations)  */
/* ------------------------------------------------------------------ */

#define BENCH_THREADED(name, threads, iterations_per_thread, func_ptr, arg) \
    do {                                                                    \
        bench_run_threaded((name), (threads), (iterations_per_thread),      \
                           (func_ptr), (arg));                             \
    } while (0)

/* ------------------------------------------------------------------ */
/* bench_compare — print delta percentage between baseline and current */
/* ------------------------------------------------------------------ */

static inline void bench_compare(const char *name,
                                  double baseline_ops,
                                  double current_ops) {
    double delta_pct = ((current_ops - baseline_ops) / baseline_ops) * 100.0;
    const char *direction = (delta_pct >= 0.0) ? "faster" : "slower";
    if (delta_pct < 0.0) delta_pct = -delta_pct;
    printf("COMPARE %-36s baseline: %12.0f ops/sec  current: %12.0f ops/sec"
           "  delta: %+.1f%% (%s)\n",
           name, baseline_ops, current_ops,
           (current_ops >= baseline_ops) ? delta_pct : -delta_pct,
           direction);
}

#endif /* BENCH_HARNESS_H */
