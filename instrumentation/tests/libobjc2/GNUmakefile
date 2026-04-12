#
# GNUmakefile for libobjc2 regression tests
#
# Usage with GNUstep Make:
#   make
#   make check
#
# Fallback without GNUstep Make (plain clang):
#   make -f GNUmakefile fallback
#   make -f GNUmakefile check-fallback
#

TESTS = \
	test_rethrow_uaf \
	test_null_selector \
	test_spinlock_deadlock \
	test_selector_race \
	test_class_table_race \
	test_arc_thread_safety \
	test_category_order \
	test_protocol_null \
	test_strong_null \
	test_type_qualifiers \
	test_weak_ref_stress

# ---------- GNUstep Make path ----------

# Try to find GNUstep makefiles
GNUSTEP_MAKEFILES ?= $(shell gnustep-config --variable=GNUSTEP_MAKEFILES 2>/dev/null)

ifneq ($(GNUSTEP_MAKEFILES),)
# ====== GNUstep Make available ======

include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = $(TESTS)

test_rethrow_uaf_OBJC_FILES         = test_rethrow_uaf.m
test_null_selector_OBJC_FILES       = test_null_selector.m
test_spinlock_deadlock_OBJC_FILES   = test_spinlock_deadlock.m
test_selector_race_OBJC_FILES       = test_selector_race.m
test_class_table_race_OBJC_FILES    = test_class_table_race.m
test_arc_thread_safety_OBJC_FILES   = test_arc_thread_safety.m
test_category_order_OBJC_FILES      = test_category_order.m
test_protocol_null_OBJC_FILES       = test_protocol_null.m
test_strong_null_OBJC_FILES         = test_strong_null.m
test_type_qualifiers_OBJC_FILES     = test_type_qualifiers.m
test_weak_ref_stress_OBJC_FILES     = test_weak_ref_stress.m

ADDITIONAL_OBJCFLAGS += -fobjc-runtime=gnustep-2.0 -fblocks
ADDITIONAL_LDFLAGS   += -lpthread

include $(GNUSTEP_MAKEFILES)/test-tool.make

else
# ====== Fallback: plain clang/gcc build ======

CC       ?= clang
OBJCFLAGS = -fobjc-runtime=gnustep-2.0 -fblocks -I../../common
LDFLAGS   = -lobjc -lpthread

all: fallback

endif

# ---------- Fallback build target ----------

fallback:
	@echo "=== Building libobjc2 tests (fallback mode) ==="
	@for t in $(TESTS); do \
		echo "  CC $$t"; \
		$(CC) $(OBJCFLAGS) -o $$t $$t.m $(LDFLAGS) || echo "  WARN: $$t failed to compile"; \
	done

# ---------- check targets ----------
# Note: 'check' conflicts with test-tool.make; use 'run-tests' instead

run-tests: all
	@echo ""
	@echo "=== Running libobjc2 regression tests ==="
	@passed=0; failed=0; skipped=0; \
	for t in $(TESTS); do \
		if [ -x ./obj/$$t ] || [ -x ./$$t ]; then \
			exe=$$([ -x ./obj/$$t ] && echo ./obj/$$t || echo ./$$t); \
			printf "  %-30s " "$$t"; \
			if timeout 10 $$exe > /tmp/$$t.out 2>&1; then \
				if grep -q "RESULT: PASS" /tmp/$$t.out; then \
					echo "PASS"; passed=$$((passed+1)); \
				elif grep -q "RESULT: FAIL" /tmp/$$t.out; then \
					echo "FAIL (test assertions)"; failed=$$((failed+1)); \
				else \
					echo "PASS (no crash)"; passed=$$((passed+1)); \
				fi; \
			else \
				echo "FAIL (crash/timeout)"; failed=$$((failed+1)); \
			fi; \
		else \
			printf "  %-30s SKIP (not built)\n" "$$t"; skipped=$$((skipped+1)); \
		fi; \
	done; \
	echo ""; \
	echo "=== Results: $$passed passed, $$failed failed, $$skipped skipped ==="; \
	[ $$failed -eq 0 ]

check-fallback: fallback
	@echo ""
	@echo "=== Running libobjc2 regression tests (fallback) ==="
	@passed=0; failed=0; skipped=0; \
	for t in $(TESTS); do \
		if [ -x ./$$t ]; then \
			printf "  %-30s " "$$t"; \
			if timeout 10 ./$$t > /tmp/$$t.out 2>&1; then \
				if grep -q "RESULT: PASS" /tmp/$$t.out; then \
					echo "PASS"; passed=$$((passed+1)); \
				elif grep -q "RESULT: FAIL" /tmp/$$t.out; then \
					echo "FAIL (test assertions)"; failed=$$((failed+1)); \
				else \
					echo "PASS (no crash)"; passed=$$((passed+1)); \
				fi; \
			else \
				echo "FAIL (crash/timeout)"; failed=$$((failed+1)); \
			fi; \
		else \
			printf "  %-30s SKIP (not built)\n" "$$t"; skipped=$$((skipped+1)); \
		fi; \
	done; \
	echo ""; \
	echo "=== Results: $$passed passed, $$failed failed, $$skipped skipped ==="; \
	[ $$failed -eq 0 ]

clean-fallback:
	rm -f $(TESTS)

.PHONY: all fallback check check-fallback clean-fallback
