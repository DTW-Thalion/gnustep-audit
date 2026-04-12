#
# GNUmakefile for libs-corebase regression tests
#
# Usage with GNUstep Make:
#   make
#   make run-tests
#
# Fallback without GNUstep Make (plain clang):
#   make -f GNUmakefile fallback
#   make -f GNUmakefile check-fallback
#
# SKIPPED: All tests require CoreFoundation headers (CFArray.h, CFSocket.h,
# CFRunLoop.h, CFString.h, CFPropertyList.h, CFNumber.h, CFDictionary.h)
# and libgnustep-corebase, which are not installed in this MSYS2 environment.
# Only CoreFoundation/CFCGTypes.h is present.
#
# To enable: install gnustep-corebase (pacman -S mingw-w64-ucrt-x86_64-gnustep-corebase
# or build from source).
#

# All tests commented out -- missing CoreFoundation headers and libgnustep-corebase
TESTS = \
#	test_cfsocket_send \
#	test_cfsocket_addr \
#	test_cfrunloop_atomic \
#	test_cfstring_surrogate \
#	test_cfplist_deepcopy \
#	test_cfarray_growth \
#	test_nscfstring_recurse \
#	test_nscfdict_enum

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

# ---------- run-tests target ----------
# Note: 'check' conflicts with test-tool.make; use 'run-tests' instead

run-tests: all
	@echo ""
	@echo "=== Running libs-corebase regression tests ==="
	@echo "SKIPPED: CoreFoundation headers and libgnustep-corebase not installed."
	@echo "All 8 tests require: CFArray.h CFSocket.h CFRunLoop.h CFString.h"
	@echo "                     CFPropertyList.h CFNumber.h CFDictionary.h CFData.h"
	@echo ""
	@echo "=== Results: 0 passed, 0 failed, 8 skipped ==="

check-fallback: fallback
	@echo ""
	@echo "=== Running libs-corebase regression tests (fallback) ==="
	@echo "SKIPPED: CoreFoundation headers and libgnustep-corebase not installed."
	@echo ""
	@echo "=== Results: 0 passed, 0 failed, 8 skipped ==="

clean-fallback:
	rm -f $(TESTS)

.PHONY: all fallback run-tests check-fallback clean-fallback
