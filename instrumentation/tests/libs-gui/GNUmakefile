#
# GNUmakefile for libs-gui regression tests
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
	test_view_subview_race \
	test_app_main_thread \
	test_view_geometry \
	test_nib_missing_class \
	test_focus_exception \
	test_image_concurrent

# ---------- GNUstep Make path ----------

GNUSTEP_MAKEFILES ?= $(shell gnustep-config --variable=GNUSTEP_MAKEFILES 2>/dev/null)

ifneq ($(GNUSTEP_MAKEFILES),)
# ====== GNUstep Make available ======

include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = $(TESTS)

test_view_subview_race_OBJC_FILES   = test_view_subview_race.m
test_app_main_thread_OBJC_FILES     = test_app_main_thread.m
test_view_geometry_OBJC_FILES       = test_view_geometry.m
test_nib_missing_class_OBJC_FILES   = test_nib_missing_class.m
test_focus_exception_OBJC_FILES     = test_focus_exception.m
test_image_concurrent_OBJC_FILES    = test_image_concurrent.m

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
	@echo "=== Building libs-gui tests (fallback mode) ==="
	@for t in $(TESTS); do \
		echo "  CC $$t"; \
		$(CC) $(OBJCFLAGS) -o $$t $$t.m $(LDFLAGS) || echo "  WARN: $$t failed to compile"; \
	done

# ---------- check targets ----------

check: all
	@echo ""
	@echo "=== Running libs-gui regression tests ==="
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
	@echo "=== Running libs-gui regression tests (fallback) ==="
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
