# Master Makefile for GNUstep Audit Instrumentation Suite
# Runs in MSYS2/bash on Windows
SHELL := /bin/bash

# ============================================================================
# Configuration
# ============================================================================

INSTRUMENTATION_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RESULTS_DIR         := $(INSTRUMENTATION_DIR)/benchmarks/results
TESTS_DIR           := $(INSTRUMENTATION_DIR)/tests
BENCHMARKS_DIR      := $(INSTRUMENTATION_DIR)/benchmarks
COMMON_DIR          := $(INSTRUMENTATION_DIR)/common

# Test repos (each has a tests/<repo>/GNUmakefile)
TEST_REPOS := libobjc2 libs-base libs-corebase libs-opal libs-quartzcore libs-gui libs-back

# Benchmark programs
BENCH_PROGRAMS := bench_msg_send bench_retain_release bench_weak_ref bench_autorelease \
                  bench_string_hash bench_dict_lookup bench_json_parse bench_runloop_timers \
                  bench_nscache bench_cfarray_append

TIMESTAMP := $(shell date +%Y-%m-%d-%H%M%S)

# ============================================================================
# Top-level targets
# ============================================================================

.PHONY: all tests benchmarks baseline compare clean help

all: tests benchmarks
	@echo ""
	@echo "=== All tests and benchmarks complete ==="

help:
	@echo "GNUstep Audit Instrumentation Suite"
	@echo "===================================="
	@echo ""
	@echo "Targets:"
	@echo "  make tests         - Run all regression tests across all repos"
	@echo "  make benchmarks    - Run all performance benchmarks"
	@echo "  make baseline      - Run benchmarks and save results as baseline"
	@echo "  make compare       - Run benchmarks and compare against baseline"
	@echo "  make clean         - Clean all build artifacts"
	@echo "  make all           - Run tests + benchmarks"
	@echo ""
	@echo "Per-repo test targets:"
	@echo "  make tests-libobjc2"
	@echo "  make tests-libs-base"
	@echo "  make tests-libs-corebase"
	@echo "  make tests-libs-opal"
	@echo "  make tests-libs-quartzcore"
	@echo "  make tests-libs-gui"
	@echo "  make tests-libs-back"
	@echo ""
	@echo "Workflow:"
	@echo "  1. make baseline     # before applying fixes"
	@echo "  2. (apply fixes)"
	@echo "  3. make compare      # after fixes, shows delta"

# ============================================================================
# Test targets
# ============================================================================

tests:
	@echo "=== Running all regression tests ==="
	@failed=0; \
	for repo in $(TEST_REPOS); do \
		echo ""; \
		echo "--- tests/$$repo ---"; \
		if [ -f "$(TESTS_DIR)/$$repo/GNUmakefile" ]; then \
			$(MAKE) -C "$(TESTS_DIR)/$$repo" check || failed=$$((failed + 1)); \
		else \
			echo "  (no GNUmakefile yet, skipping)"; \
		fi; \
	done; \
	echo ""; \
	if [ $$failed -ne 0 ]; then \
		echo "=== $$failed repo(s) had test failures ==="; \
		exit 1; \
	else \
		echo "=== All tests passed ==="; \
	fi

# Per-repo test targets
define REPO_TEST_TARGET
.PHONY: tests-$(1)
tests-$(1):
	@echo "=== Running tests for $(1) ==="
	@if [ -f "$(TESTS_DIR)/$(1)/GNUmakefile" ]; then \
		$(MAKE) -C "$(TESTS_DIR)/$(1)" check; \
	else \
		echo "  (no GNUmakefile yet for $(1))"; \
	fi
endef

$(foreach repo,$(TEST_REPOS),$(eval $(call REPO_TEST_TARGET,$(repo))))

# ============================================================================
# Benchmark targets
# ============================================================================

benchmarks:
	@echo "=== Running all benchmarks ==="
	@mkdir -p "$(RESULTS_DIR)"
	@if [ -f "$(BENCHMARKS_DIR)/GNUmakefile" ]; then \
		$(MAKE) -C "$(BENCHMARKS_DIR)" all; \
	else \
		echo "  (no benchmarks GNUmakefile yet, skipping build)"; \
	fi
	@echo ""
	@echo "--- Benchmark results ---"
	@echo "[" > "$(RESULTS_DIR)/current.json"
	@first=1; \
	for bench in $(BENCH_PROGRAMS); do \
		prog="$(BENCHMARKS_DIR)/obj/$$bench"; \
		if [ -x "$$prog" ] || [ -x "$$prog.exe" ]; then \
			if [ $$first -eq 0 ]; then echo "," >> "$(RESULTS_DIR)/current.json"; fi; \
			$$prog --json 2>/dev/null >> "$(RESULTS_DIR)/current.json" || \
			$$prog.exe --json 2>/dev/null >> "$(RESULTS_DIR)/current.json" || true; \
			first=0; \
			$$prog 2>/dev/null || $$prog.exe 2>/dev/null || true; \
		else \
			echo "  $$bench: not built, skipping"; \
		fi; \
	done
	@echo "" >> "$(RESULTS_DIR)/current.json"
	@echo "]" >> "$(RESULTS_DIR)/current.json"
	@echo ""
	@echo "Results written to $(RESULTS_DIR)/current.json"

# ============================================================================
# Baseline and compare
# ============================================================================

baseline: benchmarks
	@cp "$(RESULTS_DIR)/current.json" "$(RESULTS_DIR)/baseline.json"
	@cp "$(RESULTS_DIR)/current.json" "$(RESULTS_DIR)/baseline-$(TIMESTAMP).json"
	@echo ""
	@echo "=== Baseline saved ==="
	@echo "  $(RESULTS_DIR)/baseline.json"
	@echo "  $(RESULTS_DIR)/baseline-$(TIMESTAMP).json"

compare: benchmarks
	@if [ ! -f "$(RESULTS_DIR)/baseline.json" ]; then \
		echo "ERROR: No baseline found. Run 'make baseline' first."; \
		exit 1; \
	fi
	@echo ""
	@echo "=== Comparing current vs baseline ==="
	@python3 -c " \
import json, sys; \
try: \
    base = json.load(open('$(RESULTS_DIR)/baseline.json')); \
    curr = json.load(open('$(RESULTS_DIR)/current.json')); \
except Exception as e: \
    print(f'Error loading results: {e}'); sys.exit(1); \
base_map = {b['name']: b for b in base if isinstance(b, dict) and 'name' in b}; \
curr_map = {c['name']: c for c in curr if isinstance(c, dict) and 'name' in c}; \
all_names = sorted(set(list(base_map.keys()) + list(curr_map.keys()))); \
print(f'{\"Benchmark\":<40} {\"Baseline ns/op\":>14} {\"Current ns/op\":>14} {\"Delta\":>10} {\"Status\":>8}'); \
print('-' * 90); \
regressions = 0; \
for name in all_names: \
    b = base_map.get(name); c = curr_map.get(name); \
    if b and c: \
        bns = b['ns_per_op']; cns = c['ns_per_op']; \
        pct = ((cns - bns) / bns) * 100 if bns > 0 else 0; \
        status = 'FASTER' if pct < -2 else ('SLOWER' if pct > 5 else 'OK'); \
        if status == 'SLOWER': regressions += 1; \
        print(f'{name:<40} {bns:>14.1f} {cns:>14.1f} {pct:>+9.1f}% {status:>8}'); \
    elif b: \
        print(f'{name:<40} {b[\"ns_per_op\"]:>14.1f} {\"N/A\":>14} {\"MISSING\":>19}'); \
    else: \
        print(f'{name:<40} {\"N/A\":>14} {c[\"ns_per_op\"]:>14.1f} {\"NEW\":>19}'); \
print('-' * 90); \
if regressions: \
    print(f'WARNING: {regressions} benchmark(s) regressed (>5%% slower)'); sys.exit(1); \
else: \
    print('All benchmarks within tolerance.'); \
" 2>/dev/null || \
	awk 'BEGIN { \
		print "  (python3 not available, falling back to awk)"; \
		print "  Baseline: $(RESULTS_DIR)/baseline.json"; \
		print "  Current:  $(RESULTS_DIR)/current.json"; \
		print "  Please compare manually or install python3."; \
	}' /dev/null

# ============================================================================
# Clean
# ============================================================================

clean:
	@echo "=== Cleaning all build artifacts ==="
	@for repo in $(TEST_REPOS); do \
		if [ -f "$(TESTS_DIR)/$$repo/GNUmakefile" ]; then \
			$(MAKE) -C "$(TESTS_DIR)/$$repo" clean 2>/dev/null || true; \
		fi; \
	done
	@if [ -f "$(BENCHMARKS_DIR)/GNUmakefile" ]; then \
		$(MAKE) -C "$(BENCHMARKS_DIR)" clean 2>/dev/null || true; \
	fi
	@rm -f "$(RESULTS_DIR)/current.json"
	@echo "=== Clean complete ==="
