# A minimal app backend, configured and built by tests/cmake_check.cmake: an
# app should need nothing beyond add_library + nativebind_add_modules.
cmake_minimum_required(VERSION 3.19)
project(nativebind_cmake_check LANGUAGES C CXX)

set(NATIVEBIND_BUILD_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory("${NATIVEBIND_NATIVE_DIR}" nativebind)

add_library(cmake_check SHARED)
# Found by the compiler and, without INCLUDE_DIRS, by the generator.
target_include_directories(cmake_check PRIVATE include)
nativebind_add_modules(cmake_check SOURCES modules/sensor.cpp)
