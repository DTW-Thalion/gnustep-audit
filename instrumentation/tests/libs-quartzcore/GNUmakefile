#
# GNUmakefile for libs-quartzcore regression tests
#
# Usage with GNUstep Make:
#   make
#   make run-tests
#
# Fallback without GNUstep Make (plain clang):
#   make -f GNUmakefile fallback
#   make -f GNUmakefile check-fallback
#
# SKIPPED: All tests require QuartzCore headers and libquartzcore (+ libopal),
# which are not installed in this MSYS2 environment.
# No QuartzCore/ headers found under /c/msys64/ucrt64/include/.
#
# To enable: install gnustep-quartzcore (build from source -- not yet in MSYS2 packages).
#

# All tests commented out -- missing QuartzCore headers, libquartzcore, and libopal
TESTS = \
#	test_texture_alpha \
#	test_transaction_thread \
#	test_layer_cycle \
#	test_layer_concurrent \
#	test_texture_vla

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

# ---------- run-tests target ----------
# Note: 'check' conflicts with test-tool.make; use 'run-tests' instead

run-tests: all
	@echo ""
	@echo "=== Running libs-quartzcore regression tests ==="
	@echo "SKIPPED: QuartzCore headers, libquartzcore, and libopal not installed."
	@echo "All 5 tests require QuartzCore/ headers."
	@echo ""
	@echo "=== Results: 0 passed, 0 failed, 5 skipped ==="

check-fallback: fallback
	@echo ""
	@echo "=== Running libs-quartzcore regression tests (fallback) ==="
	@echo "SKIPPED: QuartzCore headers, libquartzcore, and libopal not installed."
	@echo ""
	@echo "=== Results: 0 passed, 0 failed, 5 skipped ==="

clean-fallback:
	rm -f $(TESTS)

.PHONY: all fallback run-tests check-fallback clean-fallback
