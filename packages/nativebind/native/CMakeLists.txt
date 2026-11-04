cmake_minimum_required(VERSION 3.18)
project(nativebind VERSION 0.2.0 LANGUAGES C CXX)

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  set(NATIVEBIND_TOP_LEVEL ON)
else()
  set(NATIVEBIND_TOP_LEVEL OFF)
endif()

option(NATIVEBIND_WITH_DART "Wake the Dart isolate through native ports (dart_api_dl)" ON)
option(NATIVEBIND_BUILD_TESTS "Build the nativebind runtime tests" ${NATIVEBIND_TOP_LEVEL})
option(NATIVEBIND_WERROR "Treat warnings as errors" ${NATIVEBIND_TOP_LEVEL})
set(NATIVEBIND_SANITIZE "" CACHE STRING "Sanitizers for the tests, e.g. address,undefined or thread")

find_package(Threads REQUIRED)

# The runtime is an OBJECT library: linking it into the app's shared library
# keeps every object (exported C ABI, static module registrations), which a
# static archive would drop.
add_library(nativebind_runtime OBJECT
  src/abi.cpp
  src/codec.cpp
  src/loop.cpp
  src/members.cpp
  src/runtime.cpp
  src/worker.cpp)
add_library(nativebind::runtime ALIAS nativebind_runtime)

target_compile_features(nativebind_runtime PUBLIC cxx_std_20)
target_include_directories(nativebind_runtime PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(nativebind_runtime PUBLIC Threads::Threads)
set_target_properties(nativebind_runtime PROPERTIES
  POSITION_INDEPENDENT_CODE ON
  CXX_VISIBILITY_PRESET hidden
  C_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON)

if(NATIVEBIND_WITH_DART)
  target_sources(nativebind_runtime PRIVATE third_party/dart_api/dart_api_dl.c)
  set_source_files_properties(third_party/dart_api/dart_api_dl.c PROPERTIES COMPILE_OPTIONS "-w")
  target_include_directories(nativebind_runtime PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/third_party/dart_api)
  target_compile_definitions(nativebind_runtime PRIVATE NATIVEBIND_WITH_DART=1)
else()
  target_compile_definitions(nativebind_runtime PRIVATE NATIVEBIND_WITH_DART=0)
endif()

set(NATIVEBIND_WARNINGS -Wall -Wextra -Wpedantic -Wshadow -Wnon-virtual-dtor -Wold-style-cast -Wcast-align
                    -Woverloaded-virtual -Wimplicit-fallthrough)
if(NATIVEBIND_WERROR)
  list(APPEND NATIVEBIND_WARNINGS -Werror)
endif()
target_compile_options(nativebind_runtime PRIVATE $<$<COMPILE_LANGUAGE:CXX>:${NATIVEBIND_WARNINGS}>)

if(NATIVEBIND_SANITIZE)
  target_compile_options(nativebind_runtime PUBLIC -fsanitize=${NATIVEBIND_SANITIZE} -fno-omit-frame-pointer)
  target_link_options(nativebind_runtime PUBLIC -fsanitize=${NATIVEBIND_SANITIZE})
  if(NATIVEBIND_SANITIZE MATCHES "undefined")
    # UBSan only prints by default; make undefined behavior fail the tests.
    target_compile_options(nativebind_runtime PUBLIC -fno-sanitize-recover=all)
    target_link_options(nativebind_runtime PUBLIC -fno-sanitize-recover=all)
  endif()
endif()

if(NATIVEBIND_BUILD_TESTS)
  enable_testing()
  add_subdirectory(tests)
endif()

include(cmake/NativeBindGenerate.cmake)
