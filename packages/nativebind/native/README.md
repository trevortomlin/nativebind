# nativebind native runtime

C++20 runtime for nativebind: bound modules, the change feed and the C ABI that
the Flutter side talks to. Requires GCC 11+ or Clang 14+ and CMake 3.18+.

This is the C++ reference. The
[repository README](../../../README.md) has the full guide, including the Dart
side.

## Writing a module

One `.cpp` file per feature. No header, no FFI code:

```cpp
#include <nativebind/nativebind.hpp>

#include <chrono>
#include <string>

using namespace std::chrono_literals;

enum class PlayState { Stopped, Playing, Paused };

class Player : public nativebind::Module {
    NATIVEBIND_MODULE(Player)
public:
    NATIVEBIND_PROP(double, volume, 0.5, .min = 0, .max = 1, .step = 0.05, .label = "Volume")
    NATIVEBIND_PROP(bool, shuffle, false)
    NATIVEBIND_READ(PlayState, state, PlayState::Stopped)
    NATIVEBIND_READ(double, position, 0.0)
    NATIVEBIND_SIGNAL(trackEnded, std::string)

    NATIVEBIND_INVOKE void play() { state = PlayState::Playing; }
    NATIVEBIND_INVOKE void seek(double seconds) { position = seconds; }

    Player() {
        volume.onWrite([this](double v) { applyVolume(v); });
    }

protected:
    void onStart() override { every(100ms, [this] { tick(); }); }

private:
    void tick() {
        if (state != PlayState::Playing) return;
        position = position + 0.1;                    // assignment updates Flutter
        if (position >= length_) trackEnded(title_);
    }
    void applyVolume(double v);
    double length_ = 180;
    std::string title_ = "Intro";
};
```

| Macro | Meaning |
|---|---|
| `NATIVEBIND_MODULE(Name[, .instanced = true][, .order = n])` | first line of the class |
| `NATIVEBIND_PROP(T, name, init[, meta…])` | UI may read and write |
| `NATIVEBIND_READ(T, name, init[, meta…])` | UI may only read |
| `NATIVEBIND_LIST(T, name)` | observable list, mirrored incrementally |
| `NATIVEBIND_SIGNAL(name, Args…)` | event |
| `NATIVEBIND_INVOKE` / `NATIVEBIND_INVOKE_AS(permission)` | method callable from the UI (`_AS`: the guard must allow it) |
| `NATIVEBIND_DART_LIBRARY("package:x/x.dart")` | in a header: its types' Dart classes come from that library |

Metadata goes in this order: `.min .max .step .label .attrs`. `.attrs` is a list of
`{key, value}` pairs (bool, integer or enum, double, string) for libraries built on
nativebind, e.g. `.attrs = {{"unit", "kPa"}, {"decimals", 1}}`. nativebind passes
them to Dart and never interprets them.

Supported types: `bool`, integers, `float`/`double`, `std::string`, enums, structs
of these (give them `bool operator==(const T&) const = default;`),
`std::vector`, `std::optional`, `std::chrono::system_clock::time_point` and
`std::chrono` durations.

### Threading

- UI writes, invokes, timers, `onStart` and `onStop` all run on the single
  **nativebind thread**, so module logic needs no locks.
- Props, lists and signals are thread-safe, so a device or network poller can
  set them from its own thread.
- Changes are coalesced: Flutter gets the latest value once per wake-up, not
  every intermediate value.

### Background threads

Blocking I/O (sockets, serial ports, device drivers) must never run on the
nativebind thread. Give the module a `nativebind::Worker`. It is a thread with a
task queue and periodic jobs, and it is joined automatically.

```cpp
class Station : public nativebind::Module {
    NATIVEBIND_MODULE(Station, .instanced = true)
public:
    NATIVEBIND_READ(double, pressure, 0.0)
    NATIVEBIND_READ(double, humidity, 0.0)
    NATIVEBIND_PROP(int32_t, interval, 500, .min = 100, .max = 5000)

    Station() {
        // UI writes arrive on the nativebind thread: forward them to the I/O thread.
        interval.onWrite([this](int32_t ms) { io_.post([this, ms] { port_.configure(ms); }); });
    }
protected:
    void onStart() override { io_.every(500ms, [this] { poll(); }); }
private:
    void poll() {                                   // on io_
        auto r = port_.read();                      // may block or throw
        nativebind::Batch batch;                    // Flutter sees all of it or none
        pressure = r.pressure;
        humidity = r.humidity;
    }
    SerialPort port_;                       // only used on io_
    nativebind::Worker io_{*this, "station-io"};  // stopped after onStop
};
```

| From a worker thread you may | Notes |
|---|---|
| set props and their metadata; change lists; emit signals | thread-safe |
| `post(fn)` to run module logic on the nativebind thread | for state shared with NATIVEBIND_INVOKE methods |
| `nativebind::Batch` to publish related values together | keep it short; no I/O inside |

| Do not | Instead |
|---|---|
| block the nativebind thread (I/O in `onWrite`, invokes, timers) | `io_.post(...)` |
| share plain members between the worker and the nativebind thread | a bound prop, or `post` |
| let a worker outlive the module | give it its module, `Worker io_{*this, "name"}`, or `io_.stop()` in `onStop()` |

`Worker::sleepFor` returns early when the worker stops, for long-running
loops. Workers get thread names (`top -H`), and exceptions in tasks are
logged rather than terminating the thread.

### Reading other modules

Single-file modules have no headers to share, so read each other by name:

```cpp
void onStart() override {   // every singleton exists by now
    volume_ = &nativebind::property<double>("Player", "volume");
}
```

The lookup is type-checked at runtime and throws a clear `std::logic_error`
on a typo or wrong type. Do the lookup in `onStart()`, not in a `static`, so a
restarted runtime never keeps stale references. For typed access, include the
generated `player.nb.hpp` and call `nativebind::ref::Player::get()`.

### Writes from the UI

1. The runtime checks writability, enabled state and the guard
   (`nativebind::setGuard`) when the write arrives, then, on the nativebind
   thread, checks enabled state again and clamps to the current `[min, max]`.
2. `validate(fn)` may accept, reject or replace the value.
3. `onWrite(fn)` runs after the value is stored.

A rejected write is echoed back, so the slider snaps back.

### Instances

```cpp
for (auto& cfg : config.stations) nativebind::spawn<Station>(cfg.id, cfg.port);  // NATIVEBIND_MODULE(Station, .instanced = true)
nativebind::destroy(station);
nativebind::singleton<Player>();
nativebind::instances<Station>();
```

### Access control (the guard)

```cpp
nativebind::setGuard([](const nativebind::GuardRequest& r) -> std::string {
    // r.kind: Write (r.meta has the property's attrs) or Invoke (r.permission)
    return allowed(r) ? "" : "requires an administrator";
});
```

It runs before every UI write (on the Flutter UI thread) and `NATIVEBIND_INVOKE_AS`
call (on the nativebind thread), with no runtime lock held: it may read other
modules' state, but keep it fast. Without one, `INVOKE_AS` calls are refused.

### Testing modules

A module is a plain object. Construct it and test its logic without the
runtime or Flutter. Tests that need the runtime call `nativebind::start()`,
`nativebind::flush()` and `nativebind::stop()` themselves.

## Building

```sh
cmake -B build -G Ninja && cmake --build build && ./build/tests/nativebind_tests
cmake -B build-asan -DCMAKE_BUILD_TYPE=Debug -DNATIVEBIND_SANITIZE=address,undefined
cmake -B build-tsan -DCMAKE_BUILD_TYPE=Debug -DNATIVEBIND_SANITIZE=thread
```

In an application, add the module sources with `nativebind_add_modules`. It
generates the glue at build time and links `nativebind::runtime` (an OBJECT
library) into your shared library. Unless you set `CXX_VISIBILITY_PRESET`
yourself, it also hides every symbol except the `nativebind_*` C functions.
The generator reads headers in the target's include directories
(`target_include_directories`) as well as in `INCLUDE_DIRS`:

```cmake
add_subdirectory(path/to/nativebind/native nativebind)
add_library(my_backend SHARED)
nativebind_add_modules(my_backend SOURCES modules/player.cpp modules/station.cpp)
```

| CMake | |
|---|---|
| `nativebind_add_modules(<target> SOURCES ... [INCLUDE_DIRS ...] [PROVIDES <uri>] [OUTPUT_DIR <dir>])` | generate and compile the glue for these modules |
| `nativebind_add_header_dirs(<dir>...)` | header directories the generator reads for every target (for libraries built on nativebind) |
| `nativebind_dart_package_dir(<package> <var> [PROJECT <dir>])` | a Dart package's root from the app's `package_config.json` |
| `NATIVEBIND_DART_PROJECT` | the Flutter app, used to find `nativebind_generator` |
| `NATIVEBIND_GENERATOR` | a full generator command, e.g. a compiled executable for cross builds |
| `NATIVEBIND_BUILD_TESTS`, `NATIVEBIND_WERROR`, `NATIVEBIND_SANITIZE` | options for building this directory on its own |

The Dart side is generated with `dart run nativebind_generator` (see
[nativebind_generator](../../nativebind_generator/README.md)).

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
| `tests/` | runtime tests, fuzzing, benchmark; `tests/modules/*.nb.cpp` is checked-in generated glue (verified by the generator's golden tests) |
| `third_party/dart_api` | Dart SDK `dart_api_dl` (BSD-3-Clause) |
