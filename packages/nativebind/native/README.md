# nativebind native runtime

C++20 runtime for nativebind: bound modules, the nativebind thread, the change
feed and the C ABI that the Flutter side talks to. Requires GCC 11+ or Clang
14+ (with RTTI) and CMake 3.18+.

The [guide](https://github.com/trevortomlin/nativebind/blob/main/docs/guide.md) documents writing modules, threading, workers, the guard and
CMake; this file covers building the runtime itself.

```cpp
#include <nativebind/nativebind.hpp>

class Player : public nativebind::Module {
    NATIVEBIND_MODULE(Player)
public:
    NATIVEBIND_PROP(double, volume, 0.5, .min = 0, .max = 1, .step = 0.05)
    NATIVEBIND_READ(double, position, 0.0)
    NATIVEBIND_SIGNAL(trackEnded, std::string)
    NATIVEBIND_INVOKE void seek(double seconds) { position = seconds; }
};
```

## In an application

```cmake
add_subdirectory(path/to/nativebind/native nativebind)
add_library(my_backend SHARED)
nativebind_add_modules(my_backend SOURCES modules/player.cpp modules/station.cpp)
```

`nativebind_add_modules` generates the glue at build time, links
`nativebind::runtime` and hides every symbol except the `nativebind_*` C ABI.
Its options and the other CMake functions are in
[Building with CMake](https://github.com/trevortomlin/nativebind/blob/main/docs/guide.md#building-with-cmake).

## Building and testing the runtime

```sh
cmake -B build -G Ninja && cmake --build build && ctest --test-dir build
cmake -B build/asan -G Ninja -DCMAKE_BUILD_TYPE=Debug -DNATIVEBIND_SANITIZE=address,undefined
cmake -B build/tsan -G Ninja -DCMAKE_BUILD_TYPE=Debug -DNATIVEBIND_SANITIZE=thread
cmake -B build/release -G Ninja -DCMAKE_BUILD_TYPE=Release && cmake --build build/release \
  && ./build/release/tests/nativebind_bench --check
```

## Layout

| Path | |
|---|---|
| `include/nativebind/nativebind.hpp` | everything a module needs |
| `include/nativebind/nativebind.h` | the C ABI used by Dart |
| `include/nativebind/glue.hpp` | interface for generated code |
| `include/nativebind/worker.hpp` | `Worker`, `Batch`, `property<T>()` |
| `src/` | runtime, nativebind thread, codec |
| `doc/wire-format.md` | byte formats of values and the change feed |
| `cmake/NativeBindGenerate.cmake` | `nativebind_add_modules()` |
| `tests/` | runtime tests, fuzzing, exit checks, CMake integration test, benchmark; `tests/modules/*.nb.cpp` is checked-in generated glue (verified by the generator's golden tests) |
| `third_party/dart_api` | Dart SDK `dart_api_dl` (BSD-3-Clause) |
