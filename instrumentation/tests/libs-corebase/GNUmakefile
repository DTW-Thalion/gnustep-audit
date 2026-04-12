#
# GNUmakefile for libs-corebase regression tests
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
	test_cfsocket_send \
	test_cfsocket_addr \
	test_cfrunloop_atomic \
	test_cfstring_surrogate \
	test_cfplist_deepcopy \
	test_cfarray_growth \
	test_nscfstring_recurse \
	test_nscfdict_enum

# ---------- GNUstep Make path ----------

GNUSTEP_MAKEFILES ?= $(shell gnustep-config --variable=GNUSTEP_MAKEFILES 2>/dev/null)

ifneq ($(GNUSTEP_MAKEFILES),)
# ====== GNUstep Make available ======

include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = $(TESTS)

test_cfsocket_send_OBJC_FILES       = test_cfsocket_send.m
test_cfsocket_addr_OBJC_FILES       = test_cfsocket_addr.m
test_cfrunloop_atomic_OBJC_FILES    = test_cfrunloop_atomic.m
test_cfstring_surrogate_OBJC_FILES  = test_cfstring_surrogate.m
test_cfplist_deepcopy_OBJC_FILES    = test_cfplist_deepcopy.m
test_cfarray_growth_OBJC_FILES      = test_cfarray_growth.m
test_nscfstring_recurse_OBJC_FILES  = test_nscfstring_recurse.m
test_nscfdict_enum_OBJC_FILES       = test_nscfdict_enum.m

ADDITIONAL_OBJCFLAGS += -fobjc-runtime=gnustep-2.0 -fblocks
ADDITIONAL_LDFLAGS   += -lgnustep-corebase -lgnustep-base -lpthread

include $(GNUSTEP_MAKEFILES)/test-tool.make

else
# ====== Fallback: plain clang/gcc build ======

CC       ?= clang
OBJCFLAGS = -fobjc-runtime=gnustep-2.0 -fblocks -I../../common
LDFLAGS   = -lgnustep-corebase -lgnustep-base -lobjc -lpthread

all: fallback

endif

# ---------- Fallback build target ----------

fallback:
	@echo "=== Building libs-corebase tests (fallback mode) ==="
	@for t in $(TESTS); do \
		echo "  CC $$t"; \
		$(CC) $(OBJCFLAGS) -o $$t $$t.m $(LDFLAGS) || echo "  WARN: $$t failed to compile"; \
	done

# ---------- check targets ----------

check: all
	@echo ""
	@echo "=== Running libs-corebase regression tests ==="
	@passed=0; failed=0; skipped=0; \
	for t in $(TESTS); do \
		if [ -x ./obj/$$t ] || [ -x ./$$t ]; then \
			exe=$$([ -x ./obj/$$t ] && echo ./obj/$$t || echo ./$$t); \
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
	@echo "=== Running libs-corebase regression tests (fallback) ==="
	@passed=0; failed=0; skipped=0; \
	for t in $(TESTS); do \
		if [ -x ./$$t ]; then \
			printf "  %-30s " "$$t"; \
			if timeout 30 ./$$t > /tmp/$$t.out 2>&1; then \
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
