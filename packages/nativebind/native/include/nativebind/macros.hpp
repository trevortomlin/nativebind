#pragma once
// The declaration macros. `nativebind_generator` reads these to produce
// the FFI glue and the typed Dart view models, so keep each one on its own
// declaration. Arguments containing top-level commas need parentheses:
// NATIVEBIND_PROP(Pair, p, (Pair{1, 2})).

#include "nativebind/list.hpp"
#include "nativebind/property.hpp"
#include "nativebind/signal.hpp"
#include "nativebind/types.hpp"

namespace nativebind::glue {
template <class T>
struct Invoker;
}

/// First line of a module class body. Options: `.instanced = true`, `.order = -10`.
#define NATIVEBIND_MODULE(Name, ...)                                    \
    template <class>                                                \
    friend struct ::nativebind::glue::Invoker;                          \
    static constexpr ::nativebind::ModuleOptions nativebind_options_{__VA_ARGS__}; \
    static constexpr const char* nativebind_name_ = #Name;

/// Property the UI can read and write. Optional metadata after the initial
/// value, in this order: .min .max .step .label .attrs (see nativebind::Meta)
#define NATIVEBIND_PROP(Type, name, initial, ...) \
    ::nativebind::Prop<Type> name{this, #name, initial, ::nativebind::Meta{__VA_ARGS__}, true};

/// Property the UI can only read.
#define NATIVEBIND_READ(Type, name, initial, ...) \
    ::nativebind::Prop<Type> name{this, #name, initial, ::nativebind::Meta{__VA_ARGS__}, false};

/// Observable list, mirrored incrementally in Flutter.
#define NATIVEBIND_LIST(Type, name) ::nativebind::List<Type> name{this, #name};

/// Event with zero or more arguments: NATIVEBIND_SIGNAL(trackChanged, std::string).
#define NATIVEBIND_SIGNAL(name, ...) ::nativebind::Signal<__VA_ARGS__> name{this, #name};

/// Marks a method callable from Flutter. Arguments and result may be any
/// supported type; it runs on the nativebind thread.
#define NATIVEBIND_INVOKE

/// Like NATIVEBIND_INVOKE, but the installed Guard must allow it. The argument
/// is an integer or enum the guard interprets, e.g. a user role:
/// NATIVEBIND_INVOKE_AS(Role::Admin) void factoryReset();
#define NATIVEBIND_INVOKE_AS(permission)

/// In a header whose enums and structs already have Dart classes in a Dart
/// library (a package built on nativebind), names that library. The generator
/// then imports those classes instead of generating copies:
/// NATIVEBIND_DART_LIBRARY("package:my_lib/my_lib.dart")
#define NATIVEBIND_DART_LIBRARY(uri)
