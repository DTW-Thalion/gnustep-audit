#
# GNUmakefile for libs-opal regression tests
#
# Usage with GNUstep Make:
#   make
#   make run-tests
#
# Fallback without GNUstep Make (plain clang):
#   make -f GNUmakefile fallback
#   make -f GNUmakefile check-fallback
#
# SKIPPED: All tests require CoreGraphics (Opal) headers and libopal,
# which are not installed in this MSYS2 environment.
# No CoreGraphics/ headers found under /c/msys64/ucrt64/include/.
#
# To enable: install gnustep-opal (build from source -- not yet in MSYS2 packages).
#

# All tests commented out -- missing CoreGraphics/Opal headers and libopal
TESTS = \
#	test_cgcontext_null \
#	test_tiff_write \
#	test_dash_buffer \
#	test_path_nan \
#	test_gstate_underflow \
#	test_jpeg_truncated

# ---------- GNUstep Make path ----------

# Try to find GNUstep makefiles
GNUSTEP_MAKEFILES ?= $(shell gnustep-config --variable=GNUSTEP_MAKEFILES 2>/dev/null)

ifneq ($(GNUSTEP_MAKEFILES),)
# ====== GNUstep Make available ======

include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = $(TESTS)

test_cgcontext_null_OBJC_FILES      = test_cgcontext_null.m
test_tiff_write_OBJC_FILES          = test_tiff_write.m
test_dash_buffer_OBJC_FILES         = test_dash_buffer.m
test_path_nan_OBJC_FILES            = test_path_nan.m
test_gstate_underflow_OBJC_FILES    = test_gstate_underflow.m
test_jpeg_truncated_OBJC_FILES      = test_jpeg_truncated.m

ADDITIONAL_OBJCFLAGS += -fobjc-runtime=gnustep-2.0
ADDITIONAL_LDFLAGS   += -lopal -lpthread

include $(GNUSTEP_MAKEFILES)/test-tool.make

else
# ====== Fallback: plain clang/gcc build ======

CC       ?= clang
OBJCFLAGS = -fobjc-runtime=gnustep-2.0 -I../../common
LDFLAGS   = -lopal -lgnustep-base -lobjc -lpthread

all: fallback

endif

# ---------- Fallback build target ----------

fallback:
	@echo "=== Building libs-opal tests (fallback mode) ==="
	@for t in $(TESTS); do \
		echo "  CC $$t"; \
		$(CC) $(OBJCFLAGS) -o $$t $$t.m $(LDFLAGS) || echo "  WARN: $$t failed to compile"; \
	done

# ---------- run-tests target ----------
# Note: 'check' conflicts with test-tool.make; use 'run-tests' instead

run-tests: all
	@echo ""
	@echo "=== Running libs-opal regression tests ==="
	@echo "SKIPPED: CoreGraphics (Opal) headers and libopal not installed."
	@echo "All 6 tests require CoreGraphics/ headers."
	@echo ""
	@echo "=== Results: 0 passed, 0 failed, 6 skipped ==="

check-fallback: fallback
	@echo ""
	@echo "=== Running libs-opal regression tests (fallback) ==="
	@echo "SKIPPED: CoreGraphics (Opal) headers and libopal not installed."
	@echo ""
	@echo "=== Results: 0 passed, 0 failed, 6 skipped ==="

clean-fallback:
	rm -f $(TESTS)

.PHONY: all fallback run-tests check-fallback clean-fallback
