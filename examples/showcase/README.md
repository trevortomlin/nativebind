# nativebind showcase

A small Linux desktop app built with [nativebind](../../README.md). Each tab is
backed by one C++ file in [`native/modules/`](native/modules); the Dart view
models in `lib/nativebind/` are generated from them.

| Tab | C++ | Shows |
|---|---|---|
| Counter | [`counter.cpp`](native/modules/counter.cpp) | a writable property with a range, a read-only value, a signal, methods |
| Player | [`player.cpp`](native/modules/player.cpp) | a simulated media player: enums, a list of structs with `Duration`s, `validate`, a timer, `Batch`, methods with results; a throttled edit session for the volume slider |
| Downloads | [`downloads.cpp`](native/modules/downloads.cpp) | instanced modules spawned and destroyed from C++, one `Worker` thread per download, C++ signal connections across modules |

## Run it

```sh
flutter pub get
dart run nativebind_generator     # writes lib/nativebind/ (already checked in)
flutter run -d linux              # also builds native/ into libshowcase_backend.so
```

## Test it

```sh
flutter test
```

- [`test/app_test.dart`](test/app_test.dart) builds the C++ backend with CMake
  and drives the whole app against it.
- [`test/fake_test.dart`](test/fake_test.dart) tests the counter page against
  `FakeNative`, without any C++.

## Use it as a template

- [`native/CMakeLists.txt`](native/CMakeLists.txt) finds nativebind through
  `.dart_tool/package_config.json` and builds the backend. Rename
  `showcase_backend` and list your modules.
- [`linux/CMakeLists.txt`](linux/CMakeLists.txt) has two additions, marked
  `showcase_backend`: build the backend with the app, and install it into the
  bundle's `lib/`.
- `pubspec_overrides.yaml` points at the packages in this repository; delete
  it in your own app.
