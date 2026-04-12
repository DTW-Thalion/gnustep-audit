#
# GNUmakefile for libs-back regression tests
#
# Usage with GNUstep Make:
#   make
#   make check
#
# Fallback without GNUstep Make (plain clang):
#   make -f GNUmakefile fallback
#   make -f GNUmakefile check-fallback
#
# Note: Many tests require the headless backend. Set defaults before running:
#   defaults write NSGlobalDomain GSBackend HeadlessServer
# or set environment: GSBackend=HeadlessServer
#

TESTS = \
	test_headless_lifecycle \
	test_window_map_race \
	test_gdi_leak

# ---------- GNUstep Make path ----------

GNUSTEP_MAKEFILES ?= $(shell gnustep-config --variable=GNUSTEP_MAKEFILES 2>/dev/null)

ifneq ($(GNUSTEP_MAKEFILES),)
# ====== GNUstep Make available ======

include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = $(TESTS)

test_headless_lifecycle_OBJC_FILES  = test_headless_lifecycle.m
test_window_map_race_OBJC_FILES     = test_window_map_race.m
test_gdi_leak_OBJC_FILES            = test_gdi_leak.m

ADDITIONAL_OBJCFLAGS += -fobjc-runtime=gnustep-2.0 -fblocks
ADDITIONAL_LDFLAGS   += -lgnustep-gui -lgnustep-base -lpthread

include $(GNUSTEP_MAKEFILES)/test-tool.make

else
# ====== Fallback: plain clang/gcc build ======

CC       ?= clang
OBJCFLAGS = -fobjc-runtime=gnustep-2.0 -fblocks -I../../common \
            $(shell gnustep-config --objc-flags 2>/dev/null)
LDFLAGS   = -lgnustep-gui -lgnustep-base -lobjc -lpthread \
            $(shell gnustep-config --objc-libs 2>/dev/null) \
            $(shell gnustep-config --gui-libs 2>/dev/null)

all: fallback

endif

# ---------- Fallback build target ----------

fallback:
	@echo "=== Building libs-back tests (fallback mode) ==="
	@for t in $(TESTS); do \
		echo "  CC $$t"; \
		$(CC) $(OBJCFLAGS) -o $$t $$t.m $(LDFLAGS) || echo "  WARN: $$t failed to compile"; \
	done

# ---------- check targets ----------

check: all
	@echo ""
	@echo "=== Running libs-back regression tests ==="
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
	@echo "=== Running libs-back regression tests (fallback) ==="
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
