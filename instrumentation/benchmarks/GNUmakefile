# GNUmakefile - GNUstep audit benchmarks
# Uses the GNUstep Make system for proper ObjC compilation

ifeq ($(GNUSTEP_MAKEFILES),)
  GNUSTEP_MAKEFILES := $(shell gnustep-config --variable=GNUSTEP_MAKEFILES 2>/dev/null)
endif
ifeq ($(GNUSTEP_MAKEFILES),)
  $(error GNUSTEP_MAKEFILES not set. Source GNUstep.sh first)
endif

include $(GNUSTEP_MAKEFILES)/common.make

# Base-only benchmarks
TOOL_NAME = bench_msg_send bench_retain_release bench_weak_ref \
            bench_autorelease bench_string_hash bench_dict_lookup \
            bench_json_parse bench_runloop_timers bench_nscache \
            bench_cfarray_append

HARNESS = ../common/bench_harness.c

bench_msg_send_OBJC_FILES = bench_msg_send.m
bench_msg_send_C_FILES = $(HARNESS)
bench_retain_release_OBJC_FILES = bench_retain_release.m
bench_retain_release_C_FILES = $(HARNESS)
bench_weak_ref_OBJC_FILES = bench_weak_ref.m
bench_weak_ref_C_FILES = $(HARNESS)
bench_weak_ref_OBJCFLAGS = -fobjc-arc
bench_autorelease_OBJC_FILES = bench_autorelease.m
bench_autorelease_C_FILES = $(HARNESS)
bench_string_hash_OBJC_FILES = bench_string_hash.m
bench_string_hash_C_FILES = $(HARNESS)
bench_dict_lookup_OBJC_FILES = bench_dict_lookup.m
bench_dict_lookup_C_FILES = $(HARNESS)
bench_json_parse_OBJC_FILES = bench_json_parse.m
bench_json_parse_C_FILES = $(HARNESS)
bench_runloop_timers_OBJC_FILES = bench_runloop_timers.m
bench_runloop_timers_C_FILES = $(HARNESS)
bench_nscache_OBJC_FILES = bench_nscache.m
bench_nscache_C_FILES = $(HARNESS)
bench_cfarray_append_OBJC_FILES = bench_cfarray_append.m
bench_cfarray_append_C_FILES = $(HARNESS)

ADDITIONAL_CPPFLAGS += -I../common
ADDITIONAL_OBJCFLAGS += -O2
ADDITIONAL_LDFLAGS += -lpthread

include $(GNUSTEP_MAKEFILES)/tool.make

# Convenience targets
.PHONY: run run-json

run: all
	@for t in $(TOOL_NAME); do \
		echo "=== $$t ==="; \
		./obj/$$t 2>&1; \
		echo; \
	done

run-json: all
	@for t in $(TOOL_NAME); do \
		./obj/$$t --json 2>&1; \
	done
