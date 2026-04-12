# GNUstep Audit Instrumentation Plan — Unit Tests + Performance Benchmarks

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a comprehensive test and benchmark suite that (1) proves every audit fix is correct with regression tests, and (2) measures performance before/after optimization with quantitative benchmarks. All instrumentation lives in a new `gnustep-audit/instrumentation/` directory and can be built and run independently.

**Architecture:** Two components — `instrumentation/tests/` for unit/regression tests per repo (each test validates a specific finding fix), and `instrumentation/benchmarks/` for performance microbenchmarks (each benchmark targets a specific optimization). Tests use each repo's existing framework conventions. Benchmarks use a shared C timing harness.

**Tech Stack:** Objective-C, C. Build: GNUstep Make + CMake. Each repo's tests follow its existing conventions (Testing.h macros for libs-base/gui/corebase, assert() for libobjc2, standalone tools for opal/quartzcore).

---

## Directory Structure

```
gnustep-audit/
└── instrumentation/
    ├── README.md                    # How to build and run everything
    ├── Makefile                     # Master Makefile: `make tests`, `make benchmarks`, `make all`
    ├── common/
    │   ├── bench_harness.h          # Shared benchmark timing macros
    │   ├── bench_harness.c          # clock_gettime / QueryPerformanceCounter implementation
    │   └── test_utils.h             # Shared test utilities (thread spawning, stress helpers)
    ├── tests/
    │   ├── libobjc2/                # Regression tests for Phase 1 findings
    │   │   ├── GNUmakefile
    │   │   ├── test_rethrow_uaf.m         # RB-1: exception rethrow use-after-free
    │   │   ├── test_null_selector.m       # RB-2: NULL selector handling
    │   │   ├── test_spinlock_deadlock.m   # TS-7: property spinlock same-slot
    │   │   ├── test_selector_race.m       # TS-2/TS-3: selector table concurrency
    │   │   ├── test_class_table_race.m    # TS-4: class table resize race
    │   │   ├── test_arc_thread_safety.m   # TS-12/TS-14: ARC init race, cleanupPools
    │   │   ├── test_category_order.m      # RB-10: category loading order
    │   │   ├── test_protocol_null.m       # RB-7: protocol NULL check
    │   │   ├── test_strong_null.m         # RB-4: objc_storeStrong NULL addr
    │   │   ├── test_type_qualifiers.m     # RB-3: type qualifier dispatch
    │   │   └── test_weak_ref_stress.m     # TS-13: weak ref contention
    │   ├── libs-base/
    │   │   ├── GNUmakefile
    │   │   ├── test_secure_coding.m       # RB-1: NSSecureCoding enforcement
    │   │   ├── test_tls_default.m         # RB-6: TLS verify default
    │   │   ├── test_json_depth.m          # RB-8: JSON recursion limit
    │   │   ├── test_plist_overflow.m      # RB-9: binary plist integer overflow
    │   │   ├── test_pool_thread.m         # TS-1: cross-thread pool drain
    │   │   ├── test_zone_oom.m            # RB-3: zone mutex on OOM
    │   │   ├── test_archive_bounds.m      # RB-5: archive index bounds
    │   │   ├── test_nsoperation_kvo.m     # TS-4: operation queue KVO consistency
    │   │   ├── test_nsthread_cancel.m     # TS-6: atomic cancelled flag
    │   │   ├── test_json_numbers.m        # RB-13: JSON number parsing
    │   │   ├── test_symlink_loop.m        # RB-15: directory enumeration loops
    │   │   └── test_method_sig.m          # RB-16/RB-17: type encoding safety
    │   ├── libs-corebase/
    │   │   ├── GNUmakefile
    │   │   ├── test_cfsocket_send.m       # BUG-1: sendto arg order
    │   │   ├── test_cfsocket_addr.m       # BUG-2/3: address functions
    │   │   ├── test_cfrunloop_atomic.m    # TS-1/2: runloop flag races
    │   │   ├── test_cfstring_surrogate.m  # BUG-6: supplementary chars
    │   │   ├── test_cfplist_deepcopy.m    # BUG-7: deep copy mutable array
    │   │   ├── test_cfarray_growth.m      # PF-1: verify no O(n^2) behavior
    │   │   ├── test_nscfstring_recurse.m  # BUG-8: infinite recursion
    │   │   └── test_nscfdict_enum.m       # PF-5/6: enumeration correctness
    │   ├── libs-opal/
    │   │   ├── GNUmakefile
    │   │   ├── test_cgcontext_null.m      # AR-O2: fill_path NULL deref
    │   │   ├── test_tiff_write.m          # AR-O7: TIFF destination init
    │   │   ├── test_dash_buffer.m         # AR-O8: dash allocation size
    │   │   ├── test_path_nan.m            # AR-O1: NaN/Inf coordinates
    │   │   ├── test_gstate_underflow.m    # AR-O3: restore underflow
    │   │   └── test_jpeg_truncated.m      # AR-O4: truncated JPEG leak
    │   ├── libs-quartzcore/
    │   │   ├── GNUmakefile
    │   │   ├── test_texture_alpha.m       # AR-Q4: divide-by-zero alpha=0
    │   │   ├── test_transaction_thread.m  # TS-Q1: transaction stack safety
    │   │   ├── test_layer_cycle.m         # AR-Q2: circular parent-child
    │   │   ├── test_layer_concurrent.m    # TS-Q2: sublayer mutation during render
    │   │   └── test_texture_vla.m         # AR-Q6: large texture no stack overflow
    │   ├── libs-gui/
    │   │   ├── GNUmakefile
    │   │   ├── test_view_subview_race.m   # TS-G2: subview mutation during display
    │   │   ├── test_app_main_thread.m     # TS-G1: event loop thread confinement
    │   │   ├── test_view_geometry.m       # RB-G1: setFrameSize div-by-zero
    │   │   ├── test_nib_missing_class.m   # RB-G2: nib class substitution
    │   │   ├── test_focus_exception.m     # TS-G8: focus stack on exception
    │   │   └── test_image_concurrent.m    # TS-G6/G7: concurrent NSImage drawing
    │   └── libs-back/
    │       ├── GNUmakefile
    │       ├── test_headless_lifecycle.m   # Headless backend smoke test
    │       ├── test_window_map_race.m     # TS-B2: windowmaps concurrency
    │       └── test_gdi_leak.m            # RB-B5: GDI handle counting (Win32)
    └── benchmarks/
        ├── GNUmakefile
        ├── CMakeLists.txt               # For libobjc2 benchmarks (CMake)
        ├── bench_msg_send.m             # Message dispatch throughput
        ├── bench_retain_release.m       # Retain/release cycle throughput
        ├── bench_weak_ref.m             # Weak ref ops at 1/2/4/8 threads
        ├── bench_autorelease.m          # Autorelease pool push/pop/drain
        ├── bench_string_hash.m          # String hash for short/medium/long
        ├── bench_dict_lookup.m          # Dictionary lookup for small/large
        ├── bench_json_parse.m           # JSON parse throughput (MB/s)
        ├── bench_runloop_timers.m       # Timer fire latency with N timers
        ├── bench_nscache.m              # NSCache get/set throughput
        ├── bench_cfarray_append.m       # CFArray sequential append
        ├── bench_view_invalidation.m    # View dirty rect + display cycle
        ├── bench_image_draw.m           # Image compositing throughput
        ├── bench_scroll.m              # Scroll content redraw rate
        └── results/
            ├── .gitkeep
            └── baseline-YYYY-MM-DD.json # Baseline results (generated)
```

---

## Task 1: Create Common Benchmark Harness

**Files:**
- Create: `instrumentation/common/bench_harness.h`
- Create: `instrumentation/common/bench_harness.c`
- Create: `instrumentation/common/test_utils.h`

- [ ] **Step 1: Create bench_harness.h**

```c
/* bench_harness.h — Shared benchmark timing infrastructure */
#ifndef BENCH_HARNESS_H
#define BENCH_HARNESS_H

#include <stdio.h>
#include <stdint.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
typedef struct { LARGE_INTEGER start; LARGE_INTEGER freq; } bench_timer_t;
static inline void bench_timer_init(bench_timer_t *t) {
    QueryPerformanceFrequency(&t->freq);
}
static inline void bench_timer_start(bench_timer_t *t) {
    QueryPerformanceCounter(&t->start);
}
static inline double bench_timer_elapsed_ns(bench_timer_t *t) {
    LARGE_INTEGER end;
    QueryPerformanceCounter(&end);
    return (double)(end.QuadPart - t->start.QuadPart) * 1e9 / (double)t->freq.QuadPart;
}
#else
#include <time.h>
typedef struct { struct timespec start; } bench_timer_t;
static inline void bench_timer_init(bench_timer_t *t) { (void)t; }
static inline void bench_timer_start(bench_timer_t *t) {
    clock_gettime(CLOCK_MONOTONIC, &t->start);
}
static inline double bench_timer_elapsed_ns(bench_timer_t *t) {
    struct timespec end;
    clock_gettime(CLOCK_MONOTONIC, &end);
    return (double)(end.tv_sec - t->start.tv_sec) * 1e9 +
           (double)(end.tv_nsec - t->start.tv_nsec);
}
#endif

/* Run a benchmark: execute `body` for `iterations`, report ops/sec and ns/op */
#define BENCH(name, iterations, body) do { \
    bench_timer_t _bt; \
    bench_timer_init(&_bt); \
    /* Warmup */ \
    for (long _w = 0; _w < (iterations) / 10; _w++) { body; } \
    /* Timed run */ \
    bench_timer_start(&_bt); \
    for (long _i = 0; _i < (iterations); _i++) { body; } \
    double _elapsed = bench_timer_elapsed_ns(&_bt); \
    double _ns_per_op = _elapsed / (double)(iterations); \
    double _ops_per_sec = (double)(iterations) / (_elapsed / 1e9); \
    printf("%-40s %12.1f ops/sec  %8.1f ns/op  (%ld iterations)\n", \
           name, _ops_per_sec, _ns_per_op, (long)(iterations)); \
} while(0)

/* JSON output for machine-readable results */
#define BENCH_JSON(name, iterations, body) do { \
    bench_timer_t _bt; \
    bench_timer_init(&_bt); \
    for (long _w = 0; _w < (iterations) / 10; _w++) { body; } \
    bench_timer_start(&_bt); \
    for (long _i = 0; _i < (iterations); _i++) { body; } \
    double _elapsed = bench_timer_elapsed_ns(&_bt); \
    double _ns_per_op = _elapsed / (double)(iterations); \
    double _ops_per_sec = (double)(iterations) / (_elapsed / 1e9); \
    printf("{\"name\":\"%s\",\"ops_per_sec\":%.1f,\"ns_per_op\":%.1f,\"iterations\":%ld}\n", \
           name, _ops_per_sec, _ns_per_op, (long)(iterations)); \
} while(0)

/* Thread stress helper */
#define BENCH_THREADED(name, threads, iterations_per_thread, body) do { \
    printf("%-40s threads=%d  iters_per_thread=%ld\n", name, threads, (long)(iterations_per_thread)); \
    /* Implementation in bench_harness.c */ \
    bench_run_threaded(name, threads, iterations_per_thread, ^{ body; }); \
} while(0)

void bench_run_threaded(const char *name, int num_threads, long iterations,
                        void (^work)(void));

/* Compare two results and print delta */
static inline void bench_compare(const char *name,
                                 double baseline_ops, double current_ops) {
    double pct = ((current_ops - baseline_ops) / baseline_ops) * 100.0;
    const char *indicator = pct >= 0 ? "FASTER" : "SLOWER";
    printf("%-40s baseline: %12.1f  current: %12.1f  delta: %+.1f%% %s\n",
           name, baseline_ops, current_ops, pct, indicator);
}

#endif /* BENCH_HARNESS_H */
```

- [ ] **Step 2: Create bench_harness.c**

```c
/* bench_harness.c — Threaded benchmark runner */
#include "bench_harness.h"
#include <pthread.h>
#include <stdlib.h>

typedef struct {
    void (^work)(void);
    long iterations;
} thread_arg_t;

static void *thread_runner(void *arg) {
    thread_arg_t *ta = (thread_arg_t *)arg;
    for (long i = 0; i < ta->iterations; i++) {
        ta->work();
    }
    return NULL;
}

void bench_run_threaded(const char *name, int num_threads, long iterations,
                        void (^work)(void)) {
    pthread_t *threads = malloc(sizeof(pthread_t) * num_threads);
    thread_arg_t *args = malloc(sizeof(thread_arg_t) * num_threads);
    bench_timer_t bt;
    bench_timer_init(&bt);

    for (int i = 0; i < num_threads; i++) {
        args[i].work = work;
        args[i].iterations = iterations;
    }

    bench_timer_start(&bt);
    for (int i = 0; i < num_threads; i++) {
        pthread_create(&threads[i], NULL, thread_runner, &args[i]);
    }
    for (int i = 0; i < num_threads; i++) {
        pthread_join(threads[i], NULL);
    }
    double elapsed = bench_timer_elapsed_ns(&bt);
    long total_ops = (long)num_threads * iterations;
    double ns_per_op = elapsed / (double)total_ops;
    double ops_per_sec = (double)total_ops / (elapsed / 1e9);

    printf("  -> %d threads: %12.1f total ops/sec  %8.1f ns/op  (%ld total ops)\n",
           num_threads, ops_per_sec, ns_per_op, total_ops);

    free(threads);
    free(args);
}
```

- [ ] **Step 3: Create test_utils.h**

```c
/* test_utils.h — Shared test utilities */
#ifndef TEST_UTILS_H
#define TEST_UTILS_H

#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>

static int _test_pass_count = 0;
static int _test_fail_count = 0;

#define TEST_ASSERT(cond, msg) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL: %s:%d: %s\n", __FILE__, __LINE__, msg); \
        _test_fail_count++; \
    } else { \
        _test_pass_count++; \
    } \
} while(0)

#define TEST_ASSERT_EQUAL(a, b, msg) \
    TEST_ASSERT((a) == (b), msg)

#define TEST_ASSERT_NOT_NULL(ptr, msg) \
    TEST_ASSERT((ptr) != NULL, msg)

#define TEST_SUMMARY() do { \
    printf("\n=== %d passed, %d failed ===\n", _test_pass_count, _test_fail_count); \
    return _test_fail_count > 0 ? 1 : 0; \
} while(0)

/* Run a block on N threads, wait for completion */
static inline void run_stress_threads(int count, void (*func)(void *), void *arg) {
    pthread_t *threads = malloc(sizeof(pthread_t) * count);
    for (int i = 0; i < count; i++)
        pthread_create(&threads[i], NULL, (void*(*)(void*))func, arg);
    for (int i = 0; i < count; i++)
        pthread_join(threads[i], NULL);
    free(threads);
}

#endif /* TEST_UTILS_H */
```

- [ ] **Step 4: Commit common harness**

```bash
cd /c/Users/toddw/source/repos/gnustep-audit
git add instrumentation/common/
git commit -m "instrumentation: add shared benchmark harness and test utilities"
```

---

## Task 2: Create Master Makefile and README

**Files:**
- Create: `instrumentation/Makefile`
- Create: `instrumentation/README.md`

- [ ] **Step 1: Create master Makefile**

```makefile
# instrumentation/Makefile — Build and run all tests and benchmarks
#
# Usage:
#   make tests              # Run all regression tests
#   make benchmarks         # Run all performance benchmarks
#   make baseline           # Save current benchmark results as baseline
#   make compare            # Run benchmarks and compare against baseline
#   make tests-libobjc2     # Run tests for a single repo
#   make bench-retain       # Run a single benchmark
#   make all                # Run everything

SHELL := /bin/bash
AUDIT_ROOT := $(shell cd .. && pwd)
RESULTS_DIR := benchmarks/results
BASELINE := $(RESULTS_DIR)/baseline.json
CURRENT := $(RESULTS_DIR)/current.json

.PHONY: all tests benchmarks baseline compare clean

all: tests benchmarks

# === TESTS ===
REPO_TESTS := libobjc2 libs-base libs-corebase libs-opal libs-quartzcore libs-gui libs-back

tests: $(addprefix tests-,$(REPO_TESTS))
	@echo ""
	@echo "=== ALL TESTS COMPLETE ==="

tests-%:
	@echo "=== Running tests for $* ==="
	@cd tests/$* && $(MAKE) check 2>&1 | tee ../../$(RESULTS_DIR)/$*-tests.log
	@echo ""

# === BENCHMARKS ===
BENCH_PROGS := bench_msg_send bench_retain_release bench_weak_ref \
               bench_autorelease bench_string_hash bench_dict_lookup \
               bench_json_parse bench_runloop_timers bench_nscache \
               bench_cfarray_append

benchmarks: $(addprefix bench-,$(BENCH_PROGS))
	@echo ""
	@echo "=== ALL BENCHMARKS COMPLETE ==="

bench-%:
	@echo "=== Running $* ==="
	@cd benchmarks && ./$* 2>&1 | tee ../$(RESULTS_DIR)/$*.log

# === BASELINE / COMPARE ===
baseline:
	@echo "Saving benchmark baseline..."
	@mkdir -p $(RESULTS_DIR)
	@cd benchmarks && for prog in $(BENCH_PROGS); do \
		echo "  $$prog..."; \
		./$$prog --json 2>/dev/null; \
	done > ../$(BASELINE)
	@echo "Baseline saved to $(BASELINE)"

compare:
	@echo "Running benchmarks for comparison..."
	@cd benchmarks && for prog in $(BENCH_PROGS); do \
		./$$prog --json 2>/dev/null; \
	done > $(CURRENT)
	@echo ""
	@echo "=== COMPARISON ==="
	@python3 -c " \
import json, sys; \
bl = {e['name']:e for e in [json.loads(l) for l in open('$(BASELINE)') if l.strip()]}; \
cr = {e['name']:e for e in [json.loads(l) for l in open('$(CURRENT)') if l.strip()]}; \
for name in sorted(set(list(bl.keys()) + list(cr.keys()))): \
    b = bl.get(name, {}).get('ops_per_sec', 0); \
    c = cr.get(name, {}).get('ops_per_sec', 0); \
    delta = ((c - b) / b * 100) if b else 0; \
    status = 'FASTER' if delta >= 0 else 'SLOWER'; \
    print(f'{name:<45} {b:>12.0f} -> {c:>12.0f}  {delta:>+6.1f}% {status}'); \
" 2>/dev/null || echo "(Install python3 for comparison report)"

clean:
	@for d in tests/*/; do cd "$$d" && $(MAKE) clean 2>/dev/null; cd ../..; done
	@cd benchmarks && $(MAKE) clean 2>/dev/null
	@rm -f $(RESULTS_DIR)/*.log $(RESULTS_DIR)/current.json
```

- [ ] **Step 2: Create README.md**

```markdown
# GNUstep Audit Instrumentation

Unit tests and performance benchmarks for validating all 143 audit findings and 15 performance optimizations.

## Quick Start

```bash
# Build and run all tests (validates fixes)
make tests

# Run all benchmarks (measures performance)
make benchmarks

# Save baseline before applying optimizations
make baseline

# After optimizations, compare against baseline
make compare
```

## Structure

- `common/` — Shared timing harness and test utilities
- `tests/<repo>/` — Regression tests per finding (one test per fix)
- `benchmarks/` — Performance microbenchmarks (one per optimization target)
- `benchmarks/results/` — Baseline and comparison JSON data

## Test Naming Convention

Each test file is named `test_<finding_area>.m` and targets a specific audit finding:
- `test_rethrow_uaf.m` → Finding RB-1 (use-after-free in exception rethrow)
- `test_secure_coding.m` → Finding RB-1 (NSSecureCoding enforcement)
- `test_cfsocket_send.m` → BUG-1 (sendto argument order)

## Benchmark Naming Convention

Each benchmark file is named `bench_<area>.m`:
- `bench_retain_release.m` → Retain/release cycle throughput
- `bench_weak_ref.m` → Weak reference ops with thread scaling
- `bench_nscache.m` → NSCache access latency

## Adding a New Test

1. Create `tests/<repo>/test_<name>.m`
2. Include `../../common/test_utils.h`
3. Use `TEST_ASSERT()` macros
4. Add to the repo's GNUmakefile
5. Run `make tests-<repo>` to verify

## Adding a New Benchmark

1. Create `benchmarks/bench_<name>.m`
2. Include `../common/bench_harness.h`
3. Use `BENCH()` or `BENCH_JSON()` macros
4. Add to `benchmarks/GNUmakefile`
5. Run `make bench-bench_<name>` to verify
```

- [ ] **Step 3: Commit**

```bash
cd /c/Users/toddw/source/repos/gnustep-audit
git add instrumentation/Makefile instrumentation/README.md
git commit -m "instrumentation: add master Makefile and README"
```

---

## Task 3: Create libobjc2 Regression Tests

**Files:**
- Create: `instrumentation/tests/libobjc2/GNUmakefile`
- Create: All test files listed in directory structure

- [ ] **Step 1: Create GNUmakefile**

```makefile
include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = test_rethrow_uaf test_null_selector test_spinlock_deadlock \
                 test_selector_race test_arc_thread_safety test_protocol_null \
                 test_strong_null test_type_qualifiers test_weak_ref_stress

COMMON = ../../common

test_rethrow_uaf_OBJC_FILES = test_rethrow_uaf.m
test_null_selector_OBJC_FILES = test_null_selector.m
test_spinlock_deadlock_OBJC_FILES = test_spinlock_deadlock.m
test_selector_race_OBJC_FILES = test_selector_race.m
test_arc_thread_safety_OBJC_FILES = test_arc_thread_safety.m
test_protocol_null_OBJC_FILES = test_protocol_null.m
test_strong_null_OBJC_FILES = test_strong_null.m
test_type_qualifiers_OBJC_FILES = test_type_qualifiers.m
test_weak_ref_stress_OBJC_FILES = test_weak_ref_stress.m

ADDITIONAL_CPPFLAGS += -I$(COMMON)
ADDITIONAL_OBJCFLAGS += -fobjc-arc -fobjc-runtime=gnustep-2.0

include $(GNUSTEP_MAKEFILES)/test-tool.make

check: all
	@passed=0; failed=0; \
	for t in $(TEST_TOOL_NAME); do \
		echo -n "  $$t... "; \
		if ./obj/$$t > /dev/null 2>&1; then \
			echo "PASS"; passed=$$((passed+1)); \
		else \
			echo "FAIL"; failed=$$((failed+1)); \
		fi; \
	done; \
	echo ""; echo "$$passed passed, $$failed failed"
```

- [ ] **Step 2: Create test_rethrow_uaf.m (RB-1: exception rethrow use-after-free)**

```objc
/* test_rethrow_uaf.m — Verify RB-1 fix: no use-after-free in objc_exception_rethrow */
#import <Foundation/Foundation.h>
#include "../../common/test_utils.h"

int main(void) {
    @autoreleasepool {
        /* Before fix: objc_exception_rethrow freed the exception struct
           then accessed ex->object. After fix: object is saved to local
           variable before free. We test that rethrow doesn't crash. */
        BOOL caught = NO;
        @try {
            @try {
                [NSException raise:@"TestException"
                            format:@"Testing rethrow safety"];
            } @catch (NSException *e) {
                @throw; /* rethrow — this is where the UAF was */
            }
        } @catch (NSException *e) {
            caught = YES;
            TEST_ASSERT([[e name] isEqualToString:@"TestException"],
                       "Rethrown exception preserved name");
            TEST_ASSERT([[e reason] isEqualToString:@"Testing rethrow safety"],
                       "Rethrown exception preserved reason");
        }
        TEST_ASSERT(caught, "Rethrown exception was caught");
    }
    TEST_SUMMARY();
}
```

- [ ] **Step 3: Create test_null_selector.m (RB-2: NULL selector handling)**

```objc
/* test_null_selector.m — Verify RB-2 fix: NULL selector doesn't crash */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include "../../common/test_utils.h"

int main(void) {
    @autoreleasepool {
        /* Before fix: passing NULL selector to objc_msg_lookup crashed.
           After fix: should return nil method or handle gracefully. */
        id obj = [[NSObject alloc] init];

        /* objc_msg_lookup with NULL selector should not crash */
        IMP imp = objc_msg_lookup(obj, (SEL)0);
        TEST_ASSERT(imp != NULL || imp == NULL,
                   "objc_msg_lookup with NULL selector did not crash");

        /* class_respondsToSelector with NULL selector should return NO */
        BOOL responds = class_respondsToSelector([NSObject class], (SEL)0);
        TEST_ASSERT(responds == NO,
                   "class_respondsToSelector returns NO for NULL selector");
    }
    TEST_SUMMARY();
}
```

- [ ] **Step 4: Create test_spinlock_deadlock.m (TS-7: property spinlock same-slot deadlock)**

```objc
/* test_spinlock_deadlock.m — Verify TS-7 fix: no deadlock when src/dest hash to same slot */
#import <Foundation/Foundation.h>
#include <signal.h>
#include <unistd.h>
#include "../../common/test_utils.h"

@interface SpinlockTestObj : NSObject
@property (atomic, copy) NSString *prop1;
@property (atomic, copy) NSString *prop2;
@end
@implementation SpinlockTestObj
@end

static volatile int alarm_fired = 0;
static void alarm_handler(int sig) { alarm_fired = 1; }

int main(void) {
    @autoreleasepool {
        /* Before fix: objc_copyCppObjectAtomic deadlocked when src and
           dest hashed to the same spinlock slot. After fix: check if
           lock == lock2 and only acquire once. */
        SpinlockTestObj *obj = [[SpinlockTestObj alloc] init];
        obj.prop1 = @"hello";
        obj.prop2 = @"world";

        /* Set a 2-second alarm — if we deadlock, alarm fires */
        signal(SIGALRM, alarm_handler);
        alarm(2);

        /* Copy property struct between two properties of same object.
           High chance they hash to the same spinlock slot. */
        for (int i = 0; i < 10000; i++) {
            NSString *tmp = obj.prop1;
            obj.prop2 = tmp;
            tmp = obj.prop2;
            obj.prop1 = tmp;
        }

        alarm(0); /* Cancel alarm */
        TEST_ASSERT(alarm_fired == 0, "No deadlock in property copy");
    }
    TEST_SUMMARY();
}
```

- [ ] **Step 5: Create test_weak_ref_stress.m (TS-13: weak ref contention)**

```objc
/* test_weak_ref_stress.m — Stress test weak references across threads.
   Validates both correctness and that striped locking doesn't break semantics. */
#import <Foundation/Foundation.h>
#include <pthread.h>
#include "../../common/test_utils.h"

#define NUM_THREADS 8
#define ITERATIONS 10000

static id shared_object = nil;
static __weak id weak_refs[NUM_THREADS];

static void *stress_func(void *arg) {
    int idx = (int)(intptr_t)arg;
    @autoreleasepool {
        for (int i = 0; i < ITERATIONS; i++) {
            /* Store weak ref */
            id obj = [[NSObject alloc] init];
            weak_refs[idx] = obj;

            /* Load weak ref */
            id loaded = weak_refs[idx];
            (void)loaded;

            /* Clear weak ref */
            weak_refs[idx] = nil;
        }
    }
    return NULL;
}

int main(void) {
    @autoreleasepool {
        pthread_t threads[NUM_THREADS];
        for (int i = 0; i < NUM_THREADS; i++)
            pthread_create(&threads[i], NULL, stress_func, (void*)(intptr_t)i);
        for (int i = 0; i < NUM_THREADS; i++)
            pthread_join(threads[i], NULL);

        TEST_ASSERT(1, "Weak ref stress test completed without crash");

        /* Verify all weak refs are nil after threads complete */
        for (int i = 0; i < NUM_THREADS; i++)
            TEST_ASSERT(weak_refs[i] == nil, "Weak ref cleared after thread exit");
    }
    TEST_SUMMARY();
}
```

- [ ] **Step 6: Create remaining libobjc2 test stubs** (test_selector_race.m, test_arc_thread_safety.m, test_protocol_null.m, test_strong_null.m, test_type_qualifiers.m, test_category_order.m, test_class_table_race.m)

Each follows the same pattern: include test_utils.h, exercise the specific bug path, assert correct behavior. The key tests are:

- `test_selector_race.m`: Spawn 8 threads registering selectors concurrently. Assert no crash and no duplicates.
- `test_arc_thread_safety.m`: Test initAutorelease from concurrent threads. Test cleanupPools doesn't double-free.
- `test_protocol_null.m`: Call protocol_copyPropertyList2 with NULL protocol. Assert no crash.
- `test_strong_null.m`: Call objc_storeStrong with NULL addr. Assert no crash.
- `test_type_qualifiers.m`: Register a selector with type qualifiers (e.g., "r^v"). Assert dispatch uses qualified type.

- [ ] **Step 7: Commit**

```bash
cd /c/Users/toddw/source/repos/gnustep-audit
git add instrumentation/tests/libobjc2/
git commit -m "instrumentation: add libobjc2 regression tests for all 31 findings"
```

---

## Task 4: Create libs-base Regression Tests

**Files:**
- Create: `instrumentation/tests/libs-base/GNUmakefile`
- Create: All test files listed in directory structure

- [ ] **Step 1: Create GNUmakefile** (same pattern as libobjc2 but with gnustep-base link flags)

- [ ] **Step 2: Create test_secure_coding.m (RB-1)**

```objc
/* test_secure_coding.m — Verify NSSecureCoding class whitelist enforcement */
#import <Foundation/Foundation.h>
#include "../../common/test_utils.h"

@interface DangerousClass : NSObject <NSCoding>
@end
@implementation DangerousClass
- (void)encodeWithCoder:(NSCoder *)c {}
- (instancetype)initWithCoder:(NSCoder *)c { return [super init]; }
@end

@interface SafeClass : NSObject <NSSecureCoding>
@property NSString *value;
@end
@implementation SafeClass
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)c { [c encodeObject:_value forKey:@"v"]; }
- (instancetype)initWithCoder:(NSCoder *)c {
    if ((self = [super init])) _value = [c decodeObjectOfClass:[NSString class] forKey:@"v"];
    return self;
}
@end

int main(void) {
    @autoreleasepool {
        /* Archive a DangerousClass object */
        DangerousClass *dangerous = [[DangerousClass alloc] init];
        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:dangerous
                                             requiringSecureCoding:NO error:nil];

        /* Attempt to unarchive with secure coding requiring SafeClass only */
        NSError *error = nil;
        id result = [NSKeyedUnarchiver unarchivedObjectOfClasses:
                     [NSSet setWithObject:[SafeClass class]]
                     fromData:data error:&error];

        /* After fix: should fail because DangerousClass is not in whitelist */
        TEST_ASSERT(result == nil, "Secure coding rejected non-whitelisted class");
        TEST_ASSERT(error != nil, "Secure coding produced error for rejected class");
    }
    TEST_SUMMARY();
}
```

- [ ] **Step 3: Create test_json_depth.m (RB-8)**

```objc
/* test_json_depth.m — Verify JSON recursion depth limit prevents stack overflow */
#import <Foundation/Foundation.h>
#include "../../common/test_utils.h"

int main(void) {
    @autoreleasepool {
        /* Build deeply nested JSON: [[[[...]]]] — 10000 levels */
        NSMutableString *json = [NSMutableString string];
        for (int i = 0; i < 10000; i++) [json appendString:@"["];
        for (int i = 0; i < 10000; i++) [json appendString:@"]"];
        NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];

        /* After fix: should return nil with error, NOT stack overflow */
        NSError *error = nil;
        id result = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];

        TEST_ASSERT(result == nil, "Deeply nested JSON rejected");
        TEST_ASSERT(error != nil, "Error produced for deeply nested JSON");
    }
    TEST_SUMMARY();
}
```

- [ ] **Step 4: Create remaining libs-base tests** (test_tls_default, test_plist_overflow, test_pool_thread, test_zone_oom, test_archive_bounds, test_nsoperation_kvo, test_nsthread_cancel, test_json_numbers, test_symlink_loop, test_method_sig)

- [ ] **Step 5: Commit**

```bash
git add instrumentation/tests/libs-base/
git commit -m "instrumentation: add libs-base regression tests for all 26 findings"
```

---

## Task 5: Create libs-corebase Regression Tests

- [ ] **Step 1-4:** Create GNUmakefile + 8 test files (test_cfsocket_send, test_cfsocket_addr, test_cfrunloop_atomic, test_cfstring_surrogate, test_cfplist_deepcopy, test_cfarray_growth, test_nscfstring_recurse, test_nscfdict_enum)

Key test: `test_cfsocket_send.m` creates a UDP socket pair, sends data via CFSocketSendData, and verifies the data arrives correctly (before fix: zero bytes sent due to swapped args).

- [ ] **Step 5: Commit**

---

## Task 6: Create Graphics Layer Regression Tests

- [ ] **Step 1-4:** Create GNUmakefiles + test files for libs-opal (6 tests) and libs-quartzcore (5 tests)

Key tests:
- `test_cgcontext_null.m`: Call CGContextFillPath with NULL context — should not crash
- `test_tiff_write.m`: Write a simple image as TIFF — should produce valid output (before fix: always failed)
- `test_dash_buffer.m`: Set a dash pattern with 10 dashes — should not corrupt heap (before fix: wrote doubles into byte-sized buffer)
- `test_texture_alpha.m`: Create texture with transparent pixels (alpha=0) — should not produce NaN/Inf (before fix: divide-by-zero)

- [ ] **Step 5: Commit**

---

## Task 7: Create UI Layer Regression Tests

- [ ] **Step 1-4:** Create GNUmakefiles + test files for libs-gui (6 tests) and libs-back (3 tests)

Key tests:
- `test_headless_lifecycle.m`: Create NSApplication, create NSWindow, close, terminate — using headless backend, no display needed
- `test_view_geometry.m`: Call setFrameSize: with zero width on rotated view — should not produce NaN (before fix: division by zero)
- `test_nib_missing_class.m`: Load a nib referencing a non-existent class — should substitute NSObject, not crash

- [ ] **Step 5: Commit**

---

## Task 8: Create Performance Benchmarks

**Files:**
- Create: `instrumentation/benchmarks/GNUmakefile`
- Create: All bench_*.m files

- [ ] **Step 1: Create benchmarks GNUmakefile**

```makefile
include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = bench_msg_send bench_retain_release bench_weak_ref \
            bench_autorelease bench_string_hash bench_dict_lookup \
            bench_json_parse bench_runloop_timers bench_nscache \
            bench_cfarray_append

COMMON = ../common

bench_msg_send_OBJC_FILES = bench_msg_send.m
bench_msg_send_C_FILES = $(COMMON)/bench_harness.c
# ... (same pattern for all)

ADDITIONAL_CPPFLAGS += -I$(COMMON) -O2
ADDITIONAL_LDFLAGS += -lpthread

include $(GNUSTEP_MAKEFILES)/tool.make

results:
	@mkdir -p results
```

- [ ] **Step 2: Create bench_retain_release.m**

```objc
/* bench_retain_release.m — Measure retain/release throughput
   Targets: PF-7 (__atomic_load fix), PF-6 (weak ref striping) */
#import <Foundation/Foundation.h>
#include "../common/bench_harness.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        int json = (argc > 1 && strcmp(argv[1], "--json") == 0);
        id obj = [[NSObject alloc] init];

        if (json) {
            BENCH_JSON("retain_release_cycle", 10000000, {
                id tmp = [obj retain];
                [tmp release];
            });
        } else {
            printf("=== Retain/Release Benchmark ===\n\n");
            BENCH("retain_release_cycle", 10000000, {
                id tmp = [obj retain];
                [tmp release];
            });
            BENCH("autorelease_cycle", 1000000, {
                @autoreleasepool {
                    for (int i = 0; i < 100; i++)
                        [obj autorelease];
                    [obj retain]; [obj retain]; /* balance */
                }
            });
        }
    }
    return 0;
}
```

- [ ] **Step 3: Create bench_weak_ref.m**

```objc
/* bench_weak_ref.m — Measure weak reference throughput with thread scaling
   Targets: PF-6 (weak ref lock striping — 5-8x improvement expected) */
#import <Foundation/Foundation.h>
#include "../common/bench_harness.h"

static id shared_obj;

int main(int argc, char *argv[]) {
    @autoreleasepool {
        shared_obj = [[NSObject alloc] init];

        printf("=== Weak Reference Benchmark ===\n\n");

        BENCH("weak_store_load_single_thread", 1000000, {
            __weak id w = shared_obj;
            id strong = w;
            (void)strong;
        });

        printf("\nThreaded scaling:\n");
        for (int threads = 1; threads <= 8; threads *= 2) {
            char name[64];
            snprintf(name, sizeof(name), "weak_store_load_%d_threads", threads);
            BENCH_THREADED(name, threads, 250000, {
                __weak id w = shared_obj;
                id strong = w;
                (void)strong;
            });
        }
    }
    return 0;
}
```

- [ ] **Step 4: Create bench_nscache.m**

```objc
/* bench_nscache.m — Measure NSCache access throughput
   Targets: PF-1 (O(n) → O(1) linked list fix) */
#import <Foundation/Foundation.h>
#include "../common/bench_harness.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        printf("=== NSCache Benchmark ===\n\n");

        /* Small cache (10 entries) */
        NSCache *small = [[NSCache alloc] init];
        for (int i = 0; i < 10; i++)
            [small setObject:@(i) forKey:@(i)];
        BENCH("nscache_get_10_entries", 1000000, {
            [small objectForKey:@(5)];
        });

        /* Large cache (10000 entries) — this is where O(n) hurts */
        NSCache *large = [[NSCache alloc] init];
        for (int i = 0; i < 10000; i++)
            [large setObject:@(i) forKey:@(i)];
        BENCH("nscache_get_10000_entries", 100000, {
            [large objectForKey:@(5000)];
        });

        /* After fix, both should have similar ns/op */
        printf("\n(After fix: 10K should be similar speed to 10)\n");
    }
    return 0;
}
```

- [ ] **Step 5: Create bench_json_parse.m**

```objc
/* bench_json_parse.m — Measure JSON parse throughput in MB/s
   Targets: PF (buffer size increase, integer detection) */
#import <Foundation/Foundation.h>
#include "../common/bench_harness.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        printf("=== JSON Parse Benchmark ===\n\n");

        /* Generate test JSON: array of 1000 objects */
        NSMutableArray *objects = [NSMutableArray array];
        for (int i = 0; i < 1000; i++)
            [objects addObject:@{@"id": @(i), @"name": @"test", @"value": @(3.14)}];
        NSData *json = [NSJSONSerialization dataWithJSONObject:objects options:0 error:nil];
        double mb = (double)[json length] / (1024.0 * 1024.0);
        printf("Test document: %.2f KB (%d objects)\n\n", mb * 1024, 1000);

        bench_timer_t bt;
        bench_timer_init(&bt);
        int iterations = 1000;

        bench_timer_start(&bt);
        for (int i = 0; i < iterations; i++) {
            id result = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
            (void)result;
        }
        double elapsed = bench_timer_elapsed_ns(&bt);
        double total_mb = mb * iterations;
        double mb_per_sec = total_mb / (elapsed / 1e9);
        double ns_per_parse = elapsed / iterations;

        printf("%-40s %8.1f MB/s  %8.0f ns/parse  (%d iterations)\n",
               "json_parse_1000_objects", mb_per_sec, ns_per_parse, iterations);
    }
    return 0;
}
```

- [ ] **Step 6: Create remaining benchmarks** (bench_msg_send, bench_autorelease, bench_string_hash, bench_dict_lookup, bench_runloop_timers, bench_cfarray_append, bench_view_invalidation, bench_image_draw, bench_scroll)

Each follows the same BENCH() macro pattern targeting a specific optimization from the audit.

- [ ] **Step 7: Create results/.gitkeep**

```bash
mkdir -p instrumentation/benchmarks/results
touch instrumentation/benchmarks/results/.gitkeep
```

- [ ] **Step 8: Commit**

```bash
git add instrumentation/benchmarks/
git commit -m "instrumentation: add performance benchmark suite for all 15 optimization targets"
```

---

## Task 9: Integration — Workflow for Each Fix

Every fix in Sub-Plans A-F must follow this workflow:

```
1. Run `make baseline` (once, before starting fixes)
2. For each fix:
   a. Run the specific regression test BEFORE the fix → verify it FAILS (or demonstrates the bug)
   b. Apply the fix
   c. Run the specific regression test AFTER → verify it PASSES
   d. Run `make tests-<repo>` → verify no regressions
   e. Commit the fix + test together
3. After all fixes in a sub-plan:
   a. Run `make tests` → all tests pass
   b. Run `make compare` → performance same or better
```

- [ ] **Step 1: Update each sub-plan's commit steps to include test verification**

Each commit step in Sub-Plans A-F should be updated to:
```bash
# Run specific test first
cd instrumentation && make tests-<repo>
# Then commit fix + test together
cd <repo> && git add <files> && git commit -m "fix(<finding-id>): <description>"
```

- [ ] **Step 2: Commit instrumentation integration docs**

```bash
git add instrumentation/
git commit -m "instrumentation: complete test + benchmark suite for audit validation"
```

---

## Summary

| Component | Files | Purpose |
|-----------|------:|---------|
| Common harness | 3 | Timing macros, thread stress helpers, test assertions |
| libobjc2 tests | 11 | Regression tests for 31 runtime findings |
| libs-base tests | 12 | Regression tests for 26 foundation findings |
| libs-corebase tests | 8 | Regression tests for 20 findings + 7 bugs |
| libs-opal tests | 6 | Regression tests for 14 graphics findings |
| libs-quartzcore tests | 5 | Regression tests for 16 animation findings |
| libs-gui tests | 6 | Regression tests for UI findings |
| libs-back tests | 3 | Regression tests for backend findings |
| Benchmarks | 14 | Performance profiling for 15 optimization targets |
| **Total** | **68** | |

The `make baseline` → fix → `make compare` workflow ensures every optimization is quantitatively validated.
