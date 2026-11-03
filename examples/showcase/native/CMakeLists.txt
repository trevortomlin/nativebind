# The app's C++ backend: libshowcase_backend.so with every module in modules/.
#
# `flutter run -d linux` builds it (linux/CMakeLists.txt adds this directory),
# and test/app_test.dart builds it on its own into build/native. Copy this file
# into your app: it only needs `flutter pub get` to have run first.

cmake_minimum_required(VERSION 3.19)
project(showcase_backend LANGUAGES C CXX)

# Locate the nativebind package (path, git or pub-cache dependency) through
# the app's .dart_tool/package_config.json.
set(APP_DIR "${CMAKE_CURRENT_LIST_DIR}/.." CACHE PATH "The Flutter app (for .dart_tool/package_config.json)")
get_filename_component(APP_DIR "${APP_DIR}" ABSOLUTE)
set(_config "${APP_DIR}/.dart_tool/package_config.json")
if(NOT EXISTS "${_config}")
  message(FATAL_ERROR "Run `flutter pub get` in ${APP_DIR} first (needs ${_config}).")
endif()
file(READ "${_config}" _json)
string(JSON _count LENGTH "${_json}" packages)
math(EXPR _last "${_count} - 1")
foreach(_i RANGE ${_last})
  string(JSON _name GET "${_json}" packages ${_i} name)
  if(_name STREQUAL "nativebind")
    string(JSON _uri GET "${_json}" packages ${_i} rootUri)
    if(_uri MATCHES "^file://(.*)$")
      set(NATIVEBIND_DIR "${CMAKE_MATCH_1}")
    else()
      get_filename_component(NATIVEBIND_DIR "${APP_DIR}/.dart_tool/${_uri}" ABSOLUTE)
    endif()
  endif()
endforeach()
if(NOT NATIVEBIND_DIR)
  message(FATAL_ERROR "package nativebind not found in ${_config}")
endif()

set(NATIVEBIND_DART_PROJECT "${APP_DIR}" CACHE PATH "" FORCE)  # lets nativebind find its generator
set(NATIVEBIND_BUILD_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory("${NATIVEBIND_DIR}/native" nativebind)

add_library(showcase_backend SHARED)
set_target_properties(showcase_backend PROPERTIES CXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN ON)
target_compile_options(showcase_backend PRIVATE -Wall -Wextra)
nativebind_add_modules(showcase_backend SOURCES
  modules/counter.cpp
  modules/player.cpp
  modules/downloads.cpp)
