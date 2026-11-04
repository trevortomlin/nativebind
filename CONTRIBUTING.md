# Contributing to nativebind

Thanks for helping! Bug reports, questions and pull requests are welcome on
GitHub. For anything larger than a small fix, please open an issue first so we
can agree on the approach.

## Setting up

You need Flutter (3.24 or newer), CMake 3.18+, Ninja, and GCC 11+ or Clang 14+.
The supported compiler floor is GCC 11, so don't use C++23 library features in
`packages/nativebind/native/`.

```sh
git clone https://github.com/trevortomlin/nativebind && cd nativebind
(cd packages/nativebind_generator && dart pub get)
(cd packages/nativebind && flutter pub get)
(cd examples/showcase && flutter pub get)
```

## Running the tests

```sh
# C++ runtime with AddressSanitizer + UBSan, and with ThreadSanitizer
(cd packages/nativebind/native && cmake -B build/asan -G Ninja -DCMAKE_BUILD_TYPE=Debug -DNATIVEBIND_SANITIZE=address,undefined \
   && cmake --build build/asan && ./build/asan/tests/nativebind_tests)
(cd packages/nativebind/native && cmake -B build/tsan -G Ninja -DCMAKE_BUILD_TYPE=Debug -DNATIVEBIND_SANITIZE=thread \
   && cmake --build build/tsan && ./build/tsan/tests/nativebind_tests)
(cd packages/nativebind_generator && dart analyze && dart test)
(cd packages/nativebind && flutter analyze && flutter test)     # includes integration tests against the real library
(cd examples/showcase && flutter analyze && flutter test)
```

The C++ test binaries also run through `ctest` (exit checks, and a CMake
integration test labelled `integration` that needs `dart`). Analyzers must
report "No issues found", and the C++ builds treat warnings as errors. Performance checks: `flutter test --tags perf` and
`./build/release/tests/nativebind_bench --check` from a Release build of
`packages/nativebind/native`.

## Rules that keep things consistent

**Generated files are never edited by hand.** `*.nb.cpp`, `*.nb.hpp` and
`*.nb.dart` come from the generator. After changing the generator, the macros,
`glue.hpp` or a test module, regenerate every checked-in output and review the
diff:

```sh
tool/regen.sh
```

`packages/nativebind_generator/test/golden_test.dart` lists those outputs and
fails CI when one is stale; add new fixtures there.

**The wire format and C ABI are a contract.** A change touches all of these
together: `native/include/nativebind/codec.hpp`, `native/src/runtime.cpp` and
`members.cpp`, `native/include/nativebind/nativebind.h`,
`native/doc/wire-format.md`, `lib/src/wire.dart`, `lib/src/runtime.dart`,
`lib/src/native.dart`, `lib/src/testing/fake_native.dart` and the C++ test
decoder `native/tests/feed.cpp`. Bump `NATIVEBIND_ABI_VERSION` and `abiVersion`
when the change is incompatible.

**Don't break the threading model.** Module logic runs on one nativebind
thread. Props, lists and signals are thread-safe. `Worker` handles blocking
I/O and `Batch` makes multi-value updates atomic for the UI. The guard runs
without runtime locks (on the UI's calling thread for writes, the nativebind
thread for guarded invokes), so it may call nativebind. Dart is
single-isolate and applies a whole drained batch before notifying listeners.
`packages/nativebind/native/src/runtime.cpp` documents the lock order.

**Stay domain-neutral.** nativebind has no notion of units, users, alarms or
any application domain; it offers generic hooks (attributes, the guard, module
order, `NATIVEBIND_DART_LIBRARY`) instead. Features that only make sense for
one domain belong in a library built on top.

## Pull requests

- Keep changes focused, and add tests: C++ tests in
  `packages/nativebind/native/tests`, Dart tests in `packages/nativebind/test`,
  generator tests in `packages/nativebind_generator/test` (every user-facing
  error message is covered in `errors_test.dart`).
- Update [the guide](docs/guide.md) and `CHANGELOG.md` when behavior or API changes.
- Make sure CI is green.

By contributing you agree that your contributions are licensed under the MIT
license of this repository.
