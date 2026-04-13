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
			$(MAKE) -C "$(TESTS_DIR)/$$repo" all && \
			$(MAKE) -C "$(TESTS_DIR)/$$repo" run-tests || failed=$$((failed + 1)); \
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
		$(MAKE) -C "$(TESTS_DIR)/$(1)" all && \
		$(MAKE) -C "$(TESTS_DIR)/$(1)" run-tests; \
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
	@# Output is JSONL (one JSON object per line), not a JSON array.
	@# This matches what the benchmark binaries emit with --json.
	@: > "$(RESULTS_DIR)/current.jsonl"
	@for bench in $(BENCH_PROGRAMS); do \
		prog="$(BENCHMARKS_DIR)/obj/$$bench"; \
		if [ -x "$$prog.exe" ]; then prog="$$prog.exe"; fi; \
		if [ -x "$$prog" ]; then \
			"$$prog" --json 2>/dev/null >> "$(RESULTS_DIR)/current.jsonl" || true; \
		else \
			echo "  $$bench: not built, skipping"; \
		fi; \
	done
	@echo ""
	@echo "Results written to $(RESULTS_DIR)/current.jsonl ($$(wc -l < $(RESULTS_DIR)/current.jsonl) benchmarks)"

# ============================================================================
# Baseline and compare
# ============================================================================

baseline: benchmarks
	@cp "$(RESULTS_DIR)/current.jsonl" "$(RESULTS_DIR)/baseline.jsonl"
	@cp "$(RESULTS_DIR)/current.jsonl" "$(RESULTS_DIR)/baseline-$(TIMESTAMP).jsonl"
	@echo ""
	@echo "=== Baseline saved ==="
	@echo "  $(RESULTS_DIR)/baseline.jsonl"
	@echo "  $(RESULTS_DIR)/baseline-$(TIMESTAMP).jsonl"

compare: benchmarks
	@if [ ! -f "$(RESULTS_DIR)/baseline.jsonl" ]; then \
		echo "ERROR: No baseline found. Run 'make baseline' first."; \
		exit 1; \
	fi
	@echo ""
	@echo "=== Comparing current vs baseline ==="
	@python3 "$(INSTRUMENTATION_DIR)/compare_results.py" \
		"$(RESULTS_DIR)/baseline.jsonl" \
		"$(RESULTS_DIR)/current.jsonl"

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
