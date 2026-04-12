/*
 * test_utils.h - Shared test assertion macros and stress-test utilities
 *
 * Header-only. Pure C, no Objective-C dependencies.
 * Provides assertion macros with pass/fail counters and a summary printer.
 * Also provides run_stress_threads() for concurrent stress testing.
 *
 * Supports POSIX (Linux) and Windows (MSYS2/MinGW).
 */
#ifndef TEST_UTILS_H
#define TEST_UTILS_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

/* ------------------------------------------------------------------ */
/* Static pass/fail counters (per translation unit)                    */
/* ------------------------------------------------------------------ */

static int _test_pass_count = 0;
static int _test_fail_count = 0;

/* ------------------------------------------------------------------ */
/* TEST_ASSERT — prints FAIL with file:line on failure                 */
/* ------------------------------------------------------------------ */

#define TEST_ASSERT(cond, msg)                                             \
    do {                                                                   \
        if (cond) {                                                        \
            _test_pass_count++;                                            \
        } else {                                                           \
            _test_fail_count++;                                            \
            printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, (msg));         \
        }                                                                  \
    } while (0)

/* ------------------------------------------------------------------ */
/* TEST_ASSERT_EQUAL — checks a == b                                   */
/* ------------------------------------------------------------------ */

#define TEST_ASSERT_EQUAL(a, b, msg)                                       \
    do {                                                                   \
        if ((a) == (b)) {                                                  \
            _test_pass_count++;                                            \
        } else {                                                           \
            _test_fail_count++;                                            \
            printf("FAIL %s:%d: %s (expected equal)\n",                    \
                   __FILE__, __LINE__, (msg));                             \
        }                                                                  \
    } while (0)

/* ------------------------------------------------------------------ */
/* TEST_ASSERT_NOT_NULL — checks ptr != NULL                           */
/* ------------------------------------------------------------------ */

#define TEST_ASSERT_NOT_NULL(ptr, msg)                                     \
    do {                                                                   \
        if ((ptr) != NULL) {                                               \
            _test_pass_count++;                                            \
        } else {                                                           \
            _test_fail_count++;                                            \
            printf("FAIL %s:%d: %s (got NULL)\n",                          \
                   __FILE__, __LINE__, (msg));                             \
        }                                                                  \
    } while (0)

/* ------------------------------------------------------------------ */
/* TEST_SUMMARY — prints total pass/fail, returns 1 if any failed      */
/* ------------------------------------------------------------------ */

#define TEST_SUMMARY()                                                     \
    _test_summary_impl()

static inline int _test_summary_impl(void) {
    int total = _test_pass_count + _test_fail_count;
    printf("\n=== Test Summary ===\n");
    printf("  Total:  %d\n", total);
    printf("  Passed: %d\n", _test_pass_count);
    printf("  Failed: %d\n", _test_fail_count);
    if (_test_fail_count > 0) {
        printf("  RESULT: FAIL\n\n");
        return 1;
    }
    printf("  RESULT: PASS\n\n");
    return 0;
}

/* ------------------------------------------------------------------ */
/* run_stress_threads — spawns N pthreads running func(arg),           */
/*                      waits for all to complete                      */
/* ------------------------------------------------------------------ */

typedef void *(*stress_thread_func)(void *arg);

static inline int run_stress_threads(int count,
                                      stress_thread_func func,
                                      void *arg) {
    pthread_t *threads = (pthread_t *)malloc(sizeof(pthread_t) * (size_t)count);
    if (!threads) {
        printf("FAIL: run_stress_threads: malloc failed\n");
        return -1;
    }

    for (int i = 0; i < count; i++) {
        if (pthread_create(&threads[i], NULL, func, arg) != 0) {
            printf("FAIL: run_stress_threads: pthread_create failed for thread %d\n", i);
            /* Join threads already started */
            for (int j = 0; j < i; j++) {
                pthread_join(threads[j], NULL);
            }
            free(threads);
            return -1;
        }
    }

    for (int i = 0; i < count; i++) {
        pthread_join(threads[i], NULL);
    }

    free(threads);
    return 0;
}

#endif /* TEST_UTILS_H */
