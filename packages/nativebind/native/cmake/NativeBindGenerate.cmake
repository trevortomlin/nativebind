# nativebind_add_modules(<target>
#     SOURCES <module.cpp>...
#     [INCLUDE_DIRS <dir>...]      extra directories for #include lookups (see also
#                                  nativebind_add_header_dirs)
#     [PROVIDES <dart-uri>]        generate types of headers declaring NATIVEBIND_DART_LIBRARY(<uri>)
#     [OUTPUT_DIR <dir>])          default: ${CMAKE_CURRENT_BINARY_DIR}/nativebind
#
# Generates <module>.nb.cpp (+ <module>.nb.hpp, typed references for other
# module files) for each module source at build time and adds it to <target>
# (the module source itself is compiled through it). Links
# nativebind::runtime into <target> if it is not linked yet. The generator
# also reads headers in <target>'s include directories. A shared library
# gets hidden symbol visibility (only nativebind_* is exported) unless
# CXX_VISIBILITY_PRESET is already set.
#
#     add_library(my_backend SHARED)
#     nativebind_add_modules(my_backend SOURCES modules/player.cpp modules/downloads.cpp)
#
# The generator runs as `${NATIVEBIND_DART} <nativebind_generator>/bin/nativebind_generator.dart`.
# Set NATIVEBIND_GENERATOR to a full command to override, e.g. a compiled
# executable: -DNATIVEBIND_GENERATOR=/opt/nativebind/nativebind_generator

# Functions run with the policies in effect where they are defined, so this
# applies to nativebind_add_modules() whatever the calling project requires.
if(POLICY CMP0116)
  cmake_policy(SET CMP0116 NEW)  # Ninja: DEPFILE paths relative to the build dir
endif()

set(NATIVEBIND_GENERATOR "" CACHE STRING "Command that runs nativebind_generator (default: dart + the bundled script)")
set(NATIVEBIND_DART_PROJECT "" CACHE PATH "Flutter/Dart app whose .dart_tool/package_config.json locates nativebind_generator")

# nativebind_dart_package_dir(<package> <out-var> [PROJECT <dir>])
#
# Resolves a Dart package's root directory from the app's
# .dart_tool/package_config.json (path, git and pub-cache dependencies alike).
# Sets <out-var> to "" if it cannot be found. Requires CMake 3.19+.
function(nativebind_dart_package_dir package out)
  cmake_parse_arguments(ARG "" "PROJECT" "" ${ARGN})
  set(project "${ARG_PROJECT}")
  if(NOT project)
    set(project "${NATIVEBIND_DART_PROJECT}")
  endif()
  set(${out} "" PARENT_SCOPE)
  set(config "${project}/.dart_tool/package_config.json")
  if(NOT project OR NOT EXISTS "${config}" OR CMAKE_VERSION VERSION_LESS 3.19)
    return()
  endif()
  file(READ "${config}" json)
  string(JSON count LENGTH "${json}" packages)
  math(EXPR last "${count} - 1")
  foreach(i RANGE ${last})
    string(JSON name GET "${json}" packages ${i} name)
    if(name STREQUAL package)
      string(JSON uri GET "${json}" packages ${i} rootUri)
      if(uri MATCHES "^file://(.*)$")
        set(dir "${CMAKE_MATCH_1}")
      else()
        set(dir "${project}/.dart_tool/${uri}")  # relative to the config file
      endif()
      get_filename_component(dir "${dir}" ABSOLUTE)
      set(${out} "${dir}" PARENT_SCOPE)
      return()
    endif()
  endforeach()
endfunction()
set(_NATIVEBIND_NATIVE_DIR "${CMAKE_CURRENT_LIST_DIR}/.." CACHE INTERNAL "")

function(_nativebind_generator_command out_cmd out_deps)
  if(NATIVEBIND_GENERATOR)
    separate_arguments(cmd NATIVE_COMMAND "${NATIVEBIND_GENERATOR}")
    set(${out_cmd} ${cmd} PARENT_SCOPE)
    set(${out_deps} "" PARENT_SCOPE)
    return()
  endif()

  set(script_dir "")
  nativebind_dart_package_dir(nativebind_generator from_config)
  foreach(candidate
      "${NATIVEBIND_GENERATOR_DIR}"
      "${from_config}"
      "${_NATIVEBIND_NATIVE_DIR}/../../nativebind_generator")
    if(candidate AND EXISTS "${candidate}/bin/nativebind_generator.dart")
      get_filename_component(script_dir "${candidate}" ABSOLUTE)
      break()
    endif()
  endforeach()
  if(NOT script_dir)
    message(FATAL_ERROR
      "nativebind: cannot find nativebind_generator. Set NATIVEBIND_DART_PROJECT to your Flutter app (after `flutter pub get`, "
      "with nativebind_generator in dev_dependencies), NATIVEBIND_GENERATOR_DIR to the package, or NATIVEBIND_GENERATOR to a command.")
  endif()

  find_program(NATIVEBIND_DART dart
    HINTS "$ENV{FLUTTER_ROOT}/bin" "$ENV{DART_SDK}/bin" "$ENV{HOME}/flutter/bin")
  if(NOT NATIVEBIND_DART)
    message(FATAL_ERROR "nativebind: `dart` not found. Put the Dart or Flutter SDK on PATH, or set NATIVEBIND_DART.")
  endif()

  file(GLOB_RECURSE generator_sources CONFIGURE_DEPENDS "${script_dir}/lib/*.dart")
  set(${out_cmd} "${NATIVEBIND_DART}" "${script_dir}/bin/nativebind_generator.dart" PARENT_SCOPE)
  set(${out_deps} "${script_dir}/bin/nativebind_generator.dart" ${generator_sources} PARENT_SCOPE)
endfunction()

# nativebind_add_header_dirs(<dir>...)
#   Lets the generator read headers in these directories for every
#   nativebind_add_modules call (packages built on nativebind register their
#   include directory here, so apps need no INCLUDE_DIRS for them).
function(nativebind_add_header_dirs)
  foreach(dir IN LISTS ARGN)
    get_filename_component(dir_abs "${dir}" ABSOLUTE)
    set_property(GLOBAL APPEND PROPERTY NATIVEBIND_HEADER_DIRS "${dir_abs}")
  endforeach()
endfunction()

function(nativebind_add_modules target)
  cmake_parse_arguments(ARG "" "OUTPUT_DIR;PROVIDES" "SOURCES;INCLUDE_DIRS" ${ARGN})
  if(NOT ARG_SOURCES)
    message(FATAL_ERROR "nativebind_add_modules(${target}): no SOURCES given")
  endif()
  if(NOT ARG_OUTPUT_DIR)
    set(ARG_OUTPUT_DIR "${CMAKE_CURRENT_BINARY_DIR}/nativebind")
  endif()
  _nativebind_generator_command(cmd generator_deps)

  set(include_args "")
  get_property(registered GLOBAL PROPERTY NATIVEBIND_HEADER_DIRS)
  foreach(dir IN LISTS ARG_INCLUDE_DIRS registered)
    get_filename_component(dir_abs "${dir}" ABSOLUTE)
    list(APPEND include_args -I "${dir_abs}")
  endforeach()
  # The target's own include directories (target_include_directories), as
  # the compiler sees them, so headers found there need no INCLUDE_DIRS.
  set(target_includes "$<TARGET_PROPERTY:${target},INCLUDE_DIRECTORIES>")
  list(APPEND include_args "$<$<BOOL:${target_includes}>:-I$<JOIN:${target_includes},$<SEMICOLON>-I>>")

  foreach(src IN LISTS ARG_SOURCES)
    get_filename_component(src_abs "${src}" ABSOLUTE)
    get_filename_component(stem "${src}" NAME_WE)
    set(out "${ARG_OUTPUT_DIR}/${stem}.nb.cpp")
    set(header "${ARG_OUTPUT_DIR}/${stem}.nb.hpp")
    set(depfile "${ARG_OUTPUT_DIR}/${stem}.nb.d")

    set(provides_args "")
    if(ARG_PROVIDES)
      set(provides_args --provides "${ARG_PROVIDES}")
    endif()

    set(depfile_args "")
    set(depfile_opt "")
    if(CMAKE_VERSION VERSION_GREATER_EQUAL 3.20 AND CMAKE_GENERATOR MATCHES "Ninja|Makefiles")
      set(depfile_args --depfile "${depfile}")
      set(depfile_opt DEPFILE "${depfile}")
    endif()

    add_custom_command(
      OUTPUT "${out}" "${header}"
      COMMAND ${cmd} --quiet --no-dart --cpp-out "${ARG_OUTPUT_DIR}" ${include_args} ${provides_args} ${depfile_args} "${src_abs}"
      DEPENDS "${src_abs}" ${generator_deps}
      ${depfile_opt}
      COMMENT "nativebind: generating ${stem}.nb.cpp"
      COMMAND_EXPAND_LISTS
      VERBATIM)

    # The module file is compiled through its glue; keep it visible to IDEs.
    # Listing the header makes every glue compile wait for all headers, so a
    # module may #include "<other>.nb.hpp" (typed references to another module).
    target_sources(${target} PRIVATE "${out}" "${header}" "${src_abs}")
    set_source_files_properties("${src_abs}" TARGET_DIRECTORY ${target} PROPERTIES HEADER_FILE_ONLY ON)
  endforeach()

  target_include_directories(${target} PRIVATE "${ARG_OUTPUT_DIR}")

  # Export only the nativebind_* C ABI from a shared library, unless the
  # project chose a visibility itself: exported C++ symbols would clash with
  # another nativebind library loaded into the same process.
  get_target_property(type ${target} TYPE)
  get_target_property(visibility ${target} CXX_VISIBILITY_PRESET)
  if(type MATCHES "^(SHARED|MODULE)_LIBRARY$" AND NOT visibility)
    set_target_properties(${target} PROPERTIES
      CXX_VISIBILITY_PRESET hidden C_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN ON)
  endif()

  get_target_property(linked ${target} LINK_LIBRARIES)
  if(NOT linked OR (NOT "nativebind::runtime" IN_LIST linked AND NOT "nativebind_runtime" IN_LIST linked))
    target_link_libraries(${target} PRIVATE nativebind::runtime)
  endif()
endfunction()
