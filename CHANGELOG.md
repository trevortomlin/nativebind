# Changelog

All notable changes to nativebind and nativebind_generator. Both packages
share a version number. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/) (with 0.x minor versions allowed to
break the API).

## Unreleased

### Fixed

- A record the Dart side cannot decode (for example an enum value the Dart
  enum does not have) is reported and skipped; the rest of its batch still
  applies, call results in it still complete, and the property, list or
  instance it targeted keeps its last good state. Gap-triggered resyncs are
  capped like failed drains.
- A `validate` handler that throws now rejects the write and acknowledges it
  (the error is logged); before, `write()` never completed.
- Converting a Dart `DateTime` or `Duration` that does not fit the C++
  `std::chrono` type throws a `DecodeError` (the call fails with `E_TYPE`)
  instead of overflowing. Encoding coarse C++ values beyond the microsecond
  range saturates.
- An open `nativebind::Batch` no longer blocks the Flutter UI thread: the
  drain returns nothing and the last batch to close wakes the consumer.
- `List::erase(i, count)` rejects a `count` that overflows instead of
  corrupting the list; `erase(i, 0)` with `i` past the end throws like the
  other bounds checks.
- The generator rejects enumerators outside the int32 range when the enum
  crosses the binding (they were silently truncated on the wire).
- Error messages name the real commands (`dart run nativebind_generator`,
  `nativebind_add_modules`).

## 0.1.0 - 2026-11-02

First public release.

### nativebind (Dart and C++ runtimes)

- C++20 runtime: `nativebind::Module` with `NATIVEBIND_MODULE`, `NATIVEBIND_PROP`,
  `NATIVEBIND_READ`, `NATIVEBIND_LIST`, `NATIVEBIND_SIGNAL`, `NATIVEBIND_INVOKE` and
  `NATIVEBIND_INVOKE_AS`; singleton and instanced modules (`spawn`, `destroy`,
  `instances`); module start order.
- Property metadata (range, step, label, enabled, free-form attributes) that
  can change at run time; `validate` and `onWrite` handlers.
- Incremental, versioned lists with `sync` for keyed diffs.
- One nativebind thread for module logic, timers and posting;
  `nativebind::Worker` for blocking I/O; `nativebind::Batch` for atomic groups
  of changes.
- A write/invoke guard (`nativebind::setGuard`) that fails closed for
  `NATIVEBIND_INVOKE_AS`.
- Cross-module access by name (`nativebind::property<T>`) or through generated
  typed references (`nativebind::ref::X::get()`).
- C ABI version 2 and a documented wire format.
- CMake integration: `nativebind_add_modules`, `nativebind_add_header_dirs`,
  `nativebind_dart_package_dir`.
- Dart runtime: `NativeBind.start/stop`, schema check at startup, hot-restart
  reattach, `BoundValue`/`BoundProperty` (optimistic, sequence-numbered writes;
  throttled edit sessions), `BoundList` with a change stream, `BoundSignal`,
  `BoundInstances`, `NativeBind.writeGuard`, typed exceptions.
- `FakeNative` test double (`package:nativebind/testing.dart`).

### nativebind_generator

- Dependency-free generator for `*.nb.cpp`, `*.nb.hpp` and `*.nb.dart`, run by
  CMake or `dart run nativebind_generator` (`--watch`, `--check`, `-I`,
  `--provides`, `--depfile`).
- Enums, structs, aliases, namespaces, `std::vector`, `std::optional`,
  `std::chrono` time points and durations; doc comments and enum labels
  carried to Dart; `NATIVEBIND_DART_LIBRARY` for shared Dart type libraries.
- Compiler-checked glue (`static_assert`s and structured bindings) and
  compiler-style diagnostics.
