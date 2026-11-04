add_executable(nativebind_tests
  harness.cpp
  feed.cpp
  modules/thermo.nb.cpp
  modules/device.nb.cpp
  test_codec.cpp
  test_instances.cpp
  test_lists.cpp
  test_runtime.cpp
  test_stress.cpp
  test_worker.cpp
  test_refs.cpp
  test_fuzz.cpp
  test_edge.cpp
  test_signals.cpp)

# thermo.cpp is compiled through its generated wrapper only.
set_source_files_properties(modules/thermo.cpp modules/device.cpp PROPERTIES HEADER_FILE_ONLY ON)

target_link_libraries(nativebind_tests PRIVATE nativebind::runtime)
target_include_directories(nativebind_tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_options(nativebind_tests PRIVATE ${NATIVEBIND_WARNINGS} -Wno-old-style-cast)

add_test(NAME nativebind_tests COMMAND nativebind_tests)

# Exits without stopping the runtime; onStop must run before the app's
# objects are destroyed. from-task: exit() from the nativebind thread.
add_executable(nativebind_exit_check exit_check.cpp modules/thermo.nb.cpp)
target_link_libraries(nativebind_exit_check PRIVATE nativebind::runtime)
target_include_directories(nativebind_exit_check PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_options(nativebind_exit_check PRIVATE ${NATIVEBIND_WARNINGS} -Wno-old-style-cast)
add_test(NAME nativebind_exit_check COMMAND nativebind_exit_check)
add_test(NAME nativebind_exit_from_task COMMAND nativebind_exit_check from-task)

# Builds tests/cmake_project the way an app would (needs `dart`): the
# generator sees target_include_directories, and only nativebind_* is exported.
add_test(NAME nativebind_cmake_integration
  COMMAND ${CMAKE_COMMAND}
    -DNATIVE_DIR=${CMAKE_CURRENT_SOURCE_DIR}/..
    -DBUILD_DIR=${CMAKE_CURRENT_BINARY_DIR}/cmake_project
    -DCXX=${CMAKE_CXX_COMPILER}
    -DGENERATOR=${CMAKE_GENERATOR}
    -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake_check.cmake)
set_tests_properties(nativebind_cmake_integration PROPERTIES LABELS integration)

# Shared library with the test modules, loaded by the Dart integration tests
# (packages/nativebind/test/integration_test.dart).
add_library(nativebind_test_modules SHARED modules/thermo.nb.cpp modules/device.nb.cpp)
target_link_libraries(nativebind_test_modules PRIVATE nativebind::runtime)
set_target_properties(nativebind_test_modules PROPERTIES CXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN ON)

# Benchmarks: nativebind_bench [--check]. The budget check only means something in
# an optimized build, so it is registered as a test (label "perf") only then.
add_executable(nativebind_bench bench.cpp feed.cpp modules/thermo.nb.cpp modules/device.nb.cpp)
target_link_libraries(nativebind_bench PRIVATE nativebind::runtime)
target_include_directories(nativebind_bench PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_options(nativebind_bench PRIVATE ${NATIVEBIND_WARNINGS} -Wno-old-style-cast)
if(CMAKE_BUILD_TYPE STREQUAL "Release" AND NOT NATIVEBIND_SANITIZE)
  add_test(NAME nativebind_bench_budgets COMMAND nativebind_bench --check)
  set_tests_properties(nativebind_bench_budgets PROPERTIES LABELS perf)
endif()
