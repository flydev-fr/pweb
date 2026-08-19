# CAP-8B Windows AUDIT build.
#
# This builds ONE measurement instrument - cap8b_audit_win.cpp - and nothing
# else. It is deliberately NOT a gate, NOT a product build, and NOT part of
# any shipped artifact: it compiles a probe whose entire job is to answer the
# three questions CAP-8B's Checkpoint 1 is not allowed to assume (bridge
# exposure, navigation coverage, active subresources) with real runtime
# evidence.
#
# It includes NOTHING from src/. The probe carries its own fixture corpus, its
# own scheme filter and its own bindings, and it deliberately serves hostile
# pweb://evil content - so linking it against the production adapters would
# defeat the measurement rather than support it.
#
# The dependency set is EXACTLY test/cap4w/CMakeLists.txt's, for the same
# reason CAP-4W states: the probe is written against the REAL pinned WebView2
# SDK header, because a measurement taken through a hand-transcribed COM vtable
# cannot distinguish "the engine behaves like this" from "my slot order is
# wrong". WRL (wrl.h) is header-only for classic COM, so the probe's
# Callback<>/ComPtr use needs no library beyond what CAP-4W already links.
#
# Usage (never invoked directly - test/cap8b/run_audit_win.ps1 drives it):
#   cmake -B build/cap8b/probe -S test/cap8b \
#         -DPWEB_ROOT=<repo> -DWEBVIEW_BUILD_DIR=build/webview-build-cap4w
#   cmake --build build/cap8b/probe --config Release

cmake_minimum_required(VERSION 3.20)

project(pweb_cap8b_audit LANGUAGES CXX)

if(NOT DEFINED PWEB_ROOT)
  message(FATAL_ERROR "PWEB_ROOT is required")
endif()
if(NOT DEFINED WEBVIEW_BUILD_DIR)
  message(FATAL_ERROR "WEBVIEW_BUILD_DIR is required")
endif()

cmake_path(ABSOLUTE_PATH PWEB_ROOT NORMALIZE OUTPUT_VARIABLE PWEB_ROOT_ABS)
cmake_path(ABSOLUTE_PATH WEBVIEW_BUILD_DIR NORMALIZE
  OUTPUT_VARIABLE WEBVIEW_BUILD_DIR_ABS)

set(WEBVIEW_INCLUDE "${PWEB_ROOT_ABS}/deps/webview/core/include")
set(WEBVIEW2_INCLUDE
  "${WEBVIEW_BUILD_DIR_ABS}/_deps/microsoft_web_webview2-src/build/native/include")
set(WEBVIEW_IMPORT_LIB
  "${WEBVIEW_BUILD_DIR_ABS}/core/Release/webview.lib")

# EXISTENCE FIRST. A missing input must fail here, naming the path, rather
# than surfacing later as an unresolved external or - worse - as a probe that
# built against some other WebView2 SDK that happened to be on the machine.
foreach(REQUIRED_PATH IN ITEMS
    "${WEBVIEW_INCLUDE}/webview/api.h"
    "${WEBVIEW2_INCLUDE}/WebView2.h"
    "${WEBVIEW_IMPORT_LIB}")
  if(NOT EXISTS "${REQUIRED_PATH}")
    message(FATAL_ERROR "required CAP-8B input missing: ${REQUIRED_PATH}")
  endif()
endforeach()

add_executable(cap8b_audit_win cap8b_audit_win.cpp)
target_compile_features(cap8b_audit_win PRIVATE cxx_std_17)
target_compile_definitions(cap8b_audit_win PRIVATE WEBVIEW_SHARED UNICODE _UNICODE)
# /WX on an AUDIT instrument is deliberate: a warning in a probe is a
# measurement that may not mean what it says.
target_compile_options(cap8b_audit_win PRIVATE /W4 /WX /EHsc)
target_include_directories(cap8b_audit_win PRIVATE
  "${WEBVIEW_INCLUDE}"
  "${WEBVIEW2_INCLUDE}")
target_link_libraries(cap8b_audit_win PRIVATE
  "${WEBVIEW_IMPORT_LIB}"
  ole32
  shlwapi)
