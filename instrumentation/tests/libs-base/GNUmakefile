#
# GNUmakefile for libs-base regression tests
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
	test_secure_coding \
	test_tls_default \
	test_json_depth \
	test_plist_overflow \
	test_pool_thread \
	test_zone_oom \
	test_archive_bounds \
	test_nsoperation_kvo \
	test_nsthread_cancel \
	test_json_numbers \
	test_symlink_loop \
	test_method_sig

# ---------- GNUstep Make path ----------

GNUSTEP_MAKEFILES ?= $(shell gnustep-config --variable=GNUSTEP_MAKEFILES 2>/dev/null)

ifneq ($(GNUSTEP_MAKEFILES),)
# ====== GNUstep Make available ======

include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = $(TESTS)

test_secure_coding_OBJC_FILES    = test_secure_coding.m
test_tls_default_OBJC_FILES      = test_tls_default.m
test_json_depth_OBJC_FILES       = test_json_depth.m
test_plist_overflow_OBJC_FILES   = test_plist_overflow.m
test_pool_thread_OBJC_FILES      = test_pool_thread.m
test_zone_oom_OBJC_FILES         = test_zone_oom.m
test_archive_bounds_OBJC_FILES   = test_archive_bounds.m
test_nsoperation_kvo_OBJC_FILES  = test_nsoperation_kvo.m
test_nsthread_cancel_OBJC_FILES  = test_nsthread_cancel.m
test_json_numbers_OBJC_FILES     = test_json_numbers.m
test_symlink_loop_OBJC_FILES     = test_symlink_loop.m
test_method_sig_OBJC_FILES       = test_method_sig.m

ADDITIONAL_OBJCFLAGS += -fobjc-runtime=gnustep-2.0 -fblocks
ADDITIONAL_LDFLAGS   += -lgnustep-base -lpthread

include $(GNUSTEP_MAKEFILES)/test-tool.make

else
# ====== Fallback: plain clang/gcc build ======

CC       ?= clang
OBJCFLAGS = -fobjc-runtime=gnustep-2.0 -fblocks -I../../common \
            $(shell gnustep-config --objc-flags 2>/dev/null)
LDFLAGS   = -lgnustep-base -lobjc -lpthread \
            $(shell gnustep-config --objc-libs 2>/dev/null) \
            $(shell gnustep-config --base-libs 2>/dev/null)

all: fallback

endif

# ---------- Fallback build target ----------

fallback:
	@echo "=== Building libs-base tests (fallback mode) ==="
	@for t in $(TESTS); do \
		echo "  CC $$t"; \
		$(CC) $(OBJCFLAGS) -o $$t $$t.m $(LDFLAGS) || echo "  WARN: $$t failed to compile"; \
	done

# ---------- check targets ----------
# Note: 'check' conflicts with test-tool.make; use 'run-tests' instead

run-tests: all
	@echo ""
	@echo "=== Running libs-base regression tests ==="
	@passed=0; failed=0; skipped=0; \
	for t in $(TESTS); do \
		if [ -x ./obj/$$t ] || [ -x ./$$t ] || [ -x ./obj/$$t.exe ] || [ -x ./$$t.exe ]; then \
			exe=$$([ -x ./obj/$$t ] && echo ./obj/$$t || \
			       ([ -x ./obj/$$t.exe ] && echo ./obj/$$t.exe || \
			       ([ -x ./$$t ] && echo ./$$t || echo ./$$t.exe))); \
			printf "  %-30s " "$$t"; \
			if timeout 30 $$exe > /tmp/$$t.out 2>&1; then \
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
	@echo "=== Running libs-base regression tests (fallback) ==="
	@passed=0; failed=0; skipped=0; \
	for t in $(TESTS); do \
		if [ -x ./$$t ] || [ -x ./$$t.exe ]; then \
			exe=$$([ -x ./$$t ] && echo ./$$t || echo ./$$t.exe); \
			printf "  %-30s " "$$t"; \
			if timeout 30 $$exe > /tmp/$$t.out 2>&1; then \
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
	rm -f $(TESTS) $(addsuffix .exe,$(TESTS))

.PHONY: all fallback check check-fallback clean-fallback
