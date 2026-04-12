# GNUmakefile - Build all GNUstep audit benchmarks as standalone tools
#
# Usage:
#   make                 # build all benchmarks
#   make bench_msg_send  # build a single benchmark
#   make clean           # remove build artifacts
#   make run             # build and run all benchmarks
#   make run-json        # build and run all benchmarks with --json output
#
# Requires: GNUstep environment (. /usr/share/GNUstep/Makefiles/GNUstep.sh)
# or MSYS2 with GNUstep packages installed.

CC ?= gcc
OBJC ?= $(CC)
OBJCFLAGS ?= -O2 -Wall -Wextra

# GNUstep flags (try gnustep-config first, fall back to pkg-config)
GNUSTEP_FLAGS := $(shell gnustep-config --objc-flags 2>/dev/null || \
                         pkg-config --cflags gnustep-base 2>/dev/null)
GNUSTEP_LIBS  := $(shell gnustep-config --base-libs 2>/dev/null || \
                         pkg-config --libs gnustep-base 2>/dev/null)

# If gnustep-config is not available, use sensible defaults
ifeq ($(strip $(GNUSTEP_LIBS)),)
  GNUSTEP_FLAGS = -fconstant-string-class=NSConstantString -fobjc-exceptions
  GNUSTEP_LIBS  = -lgnustep-base -lobjc -lpthread
endif

# AppKit-dependent benchmarks need gui libs
GNUSTEP_GUI_LIBS := $(shell gnustep-config --gui-libs 2>/dev/null || \
                            pkg-config --libs gnustep-gui 2>/dev/null)
ifeq ($(strip $(GNUSTEP_GUI_LIBS)),)
  GNUSTEP_GUI_LIBS = -lgnustep-gui -lgnustep-base -lobjc -lpthread
endif

HARNESS_DIR = ../common
HARNESS_SRC = $(HARNESS_DIR)/bench_harness.c
HARNESS_HDR = $(HARNESS_DIR)/bench_harness.h

CPPFLAGS += -I$(HARNESS_DIR)
LDFLAGS  += -lpthread

# Base-only benchmarks (no AppKit dependency)
BASE_BENCHMARKS = \
	bench_msg_send \
	bench_retain_release \
	bench_weak_ref \
	bench_autorelease \
	bench_string_hash \
	bench_dict_lookup \
	bench_json_parse \
	bench_runloop_timers \
	bench_nscache \
	bench_cfarray_append

# AppKit benchmarks (require GUI framework)
GUI_BENCHMARKS = \
	bench_view_invalidation \
	bench_image_draw \
	bench_scroll

ALL_BENCHMARKS = $(BASE_BENCHMARKS) $(GUI_BENCHMARKS)

.PHONY: all clean run run-json base gui

all: base gui

base: $(BASE_BENCHMARKS)

gui: $(GUI_BENCHMARKS)

# Pattern rule for base benchmarks
$(BASE_BENCHMARKS): %: %.m $(HARNESS_SRC) $(HARNESS_HDR)
	$(OBJC) $(OBJCFLAGS) $(CPPFLAGS) $(GNUSTEP_FLAGS) -o $@ $< $(HARNESS_SRC) $(GNUSTEP_LIBS) $(LDFLAGS)

# Pattern rule for GUI benchmarks
$(GUI_BENCHMARKS): %: %.m $(HARNESS_SRC) $(HARNESS_HDR)
	$(OBJC) $(OBJCFLAGS) $(CPPFLAGS) $(GNUSTEP_FLAGS) -o $@ $< $(HARNESS_SRC) $(GNUSTEP_GUI_LIBS) $(LDFLAGS)

clean:
	rm -f $(ALL_BENCHMARKS) $(addsuffix .exe,$(ALL_BENCHMARKS))

run: all
	@for b in $(ALL_BENCHMARKS); do \
		echo "=== $$b ==="; \
		./$$b; \
		echo; \
	done

run-json: all
	@echo "["
	@first=1; for b in $(ALL_BENCHMARKS); do \
		if [ "$$first" = "1" ]; then first=0; else echo ","; fi; \
		./$$b --json; \
	done
	@echo "]"
