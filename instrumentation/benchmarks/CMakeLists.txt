# CMakeLists.txt - Alternative CMake build for libobjc2-specific benchmarks
#
# Usage:
#   mkdir build && cd build
#   cmake .. -DCMAKE_C_COMPILER=clang -DCMAKE_OBJC_COMPILER=clang
#   cmake --build .
#
# This build system targets libobjc2-specific benchmarks (msg_send,
# retain_release, weak_ref, autorelease) that exercise the runtime
# directly. The remaining benchmarks use GNUstep-base and are better
# built via GNUmakefile with gnustep-config.

cmake_minimum_required(VERSION 3.16)
project(gnustep_benchmarks C OBJC)

set(CMAKE_C_STANDARD 11)
set(CMAKE_OBJC_STANDARD 11)

# Compiler flags
add_compile_options(-O2 -Wall -Wextra)

# Objective-C flags
set(CMAKE_OBJC_FLAGS "${CMAKE_OBJC_FLAGS} -fobjc-runtime=gnustep-2.0 -fobjc-exceptions")

# Harness library
set(HARNESS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../common")
add_library(bench_harness STATIC "${HARNESS_DIR}/bench_harness.c")
target_include_directories(bench_harness PUBLIC "${HARNESS_DIR}")

# Find required libraries
find_library(OBJC_LIB objc REQUIRED)
find_library(PTHREAD_LIB pthread REQUIRED)

# Try to find GNUstep-base
find_package(PkgConfig)
if(PkgConfig_FOUND)
    pkg_check_modules(GNUSTEP_BASE gnustep-base)
    pkg_check_modules(GNUSTEP_GUI gnustep-gui)
endif()

# Common link libraries for runtime-level benchmarks
set(RUNTIME_LIBS bench_harness ${OBJC_LIB} ${PTHREAD_LIB})

# Common link libraries for Foundation-level benchmarks
set(FOUNDATION_LIBS bench_harness ${PTHREAD_LIB})
if(GNUSTEP_BASE_FOUND)
    list(APPEND FOUNDATION_LIBS ${GNUSTEP_BASE_LIBRARIES})
endif()

# GUI libraries
set(GUI_LIBS bench_harness ${PTHREAD_LIB})
if(GNUSTEP_GUI_FOUND)
    list(APPEND GUI_LIBS ${GNUSTEP_GUI_LIBRARIES})
endif()

# Macro to add a benchmark target
macro(add_benchmark name)
    add_executable(${name} ${name}.m)
    target_link_libraries(${name} ${ARGN})
    target_include_directories(${name} PRIVATE "${HARNESS_DIR}")
    if(GNUSTEP_BASE_FOUND)
        target_include_directories(${name} PRIVATE ${GNUSTEP_BASE_INCLUDE_DIRS})
        target_compile_options(${name} PRIVATE ${GNUSTEP_BASE_CFLAGS_OTHER})
    endif()
endmacro()

# Runtime-level benchmarks (libobjc2 only, no Foundation required)
add_benchmark(bench_msg_send ${RUNTIME_LIBS})
add_benchmark(bench_retain_release ${RUNTIME_LIBS})
add_benchmark(bench_weak_ref ${RUNTIME_LIBS})
add_benchmark(bench_autorelease ${RUNTIME_LIBS})

# Foundation-level benchmarks
if(GNUSTEP_BASE_FOUND)
    add_benchmark(bench_string_hash ${FOUNDATION_LIBS})
    add_benchmark(bench_dict_lookup ${FOUNDATION_LIBS})
    add_benchmark(bench_json_parse ${FOUNDATION_LIBS})
    add_benchmark(bench_runloop_timers ${FOUNDATION_LIBS})
    add_benchmark(bench_nscache ${FOUNDATION_LIBS})
    add_benchmark(bench_cfarray_append ${FOUNDATION_LIBS})

    # GUI-level benchmarks
    if(GNUSTEP_GUI_FOUND)
        add_benchmark(bench_view_invalidation ${GUI_LIBS})
        target_include_directories(bench_view_invalidation PRIVATE ${GNUSTEP_GUI_INCLUDE_DIRS})

        add_benchmark(bench_image_draw ${GUI_LIBS})
        target_include_directories(bench_image_draw PRIVATE ${GNUSTEP_GUI_INCLUDE_DIRS})

        add_benchmark(bench_scroll ${GUI_LIBS})
        target_include_directories(bench_scroll PRIVATE ${GNUSTEP_GUI_INCLUDE_DIRS})
    else()
        message(STATUS "gnustep-gui not found; skipping GUI benchmarks")
    endif()
else()
    message(STATUS "gnustep-base not found; building runtime-only benchmarks")
endif()
