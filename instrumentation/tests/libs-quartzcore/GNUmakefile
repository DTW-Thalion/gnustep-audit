#
# GNUmakefile for libs-quartzcore regression tests
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
	test_texture_alpha \
	test_transaction_thread \
	test_layer_cycle \
	test_layer_concurrent \
	test_texture_vla

# ---------- GNUstep Make path ----------

# Try to find GNUstep makefiles
GNUSTEP_MAKEFILES ?= $(shell gnustep-config --variable=GNUSTEP_MAKEFILES 2>/dev/null)

ifneq ($(GNUSTEP_MAKEFILES),)
# ====== GNUstep Make available ======

include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = $(TESTS)

test_texture_alpha_OBJC_FILES       = test_texture_alpha.m
test_transaction_thread_OBJC_FILES  = test_transaction_thread.m
test_layer_cycle_OBJC_FILES         = test_layer_cycle.m
test_layer_concurrent_OBJC_FILES    = test_layer_concurrent.m
test_texture_vla_OBJC_FILES         = test_texture_vla.m

ADDITIONAL_OBJCFLAGS += -fobjc-runtime=gnustep-2.0
ADDITIONAL_LDFLAGS   += -lquartzcore -lopal -lgnustep-base -lobjc -lpthread

include $(GNUSTEP_MAKEFILES)/test-tool.make

else
# ====== Fallback: plain clang/gcc build ======

CC       ?= clang
OBJCFLAGS = -fobjc-runtime=gnustep-2.0 -I../../common
LDFLAGS   = -lquartzcore -lopal -lgnustep-base -lobjc -lpthread

all: fallback

endif

# ---------- Fallback build target ----------

fallback:
	@echo "=== Building libs-quartzcore tests (fallback mode) ==="
	@for t in $(TESTS); do \
		echo "  CC $$t"; \
		$(CC) $(OBJCFLAGS) -o $$t $$t.m $(LDFLAGS) || echo "  WARN: $$t failed to compile"; \
	done

# ---------- check targets ----------

check: all
	@echo ""
	@echo "=== Running libs-quartzcore regression tests ==="
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
	@echo "=== Running libs-quartzcore regression tests (fallback) ==="
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
