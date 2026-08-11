cmake_minimum_required(VERSION 3.20)

project(pweb_cap4w_probe LANGUAGES CXX)

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

foreach(REQUIRED_PATH IN ITEMS
    "${WEBVIEW_INCLUDE}/webview/api.h"
    "${WEBVIEW2_INCLUDE}/WebView2.h"
    "${WEBVIEW_IMPORT_LIB}")
  if(NOT EXISTS "${REQUIRED_PATH}")
    message(FATAL_ERROR "required CAP-4W input missing: ${REQUIRED_PATH}")
  endif()
endforeach()

add_executable(cap4w_probe cap4w_probe.cpp)
target_compile_features(cap4w_probe PRIVATE cxx_std_17)
target_compile_definitions(cap4w_probe PRIVATE WEBVIEW_SHARED UNICODE _UNICODE)
target_compile_options(cap4w_probe PRIVATE /W4 /WX /EHsc)
target_include_directories(cap4w_probe PRIVATE
  "${WEBVIEW_INCLUDE}"
  "${WEBVIEW2_INCLUDE}")
target_link_libraries(cap4w_probe PRIVATE
  "${WEBVIEW_IMPORT_LIB}"
  ole32
  shlwapi)

add_executable(cap4w_loader_boundary cap4w_loader_boundary.cpp)
target_compile_features(cap4w_loader_boundary PRIVATE cxx_std_17)
target_compile_definitions(cap4w_loader_boundary PRIVATE
  UNICODE
  _UNICODE)
target_compile_options(cap4w_loader_boundary PRIVATE /W4 /WX /EHsc)
target_include_directories(cap4w_loader_boundary PRIVATE
  "${WEBVIEW_INCLUDE}"
  "${WEBVIEW2_INCLUDE}")
target_link_libraries(cap4w_loader_boundary PRIVATE advapi32 ole32)
