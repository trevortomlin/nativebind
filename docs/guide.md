# nativebind guide

The complete reference for writing nativebind modules in C++ and using them
from Flutter. The [README](../README.md) has the overview and the quick start;
[`wire-format.md`](../packages/nativebind/native/doc/wire-format.md) documents
the bytes between the two sides.

## Contents

- [Writing modules (C++)](#writing-modules-c)
- [Using modules (Dart)](#using-modules-dart)
- [Threads and background I/O](#threads-and-background-io)
- [Access control](#access-control)
- [Extending nativebind](#extending-nativebind)
- [Testing](#testing)
- [Building with CMake](#building-with-cmake)
- [The generator](#the-generator)
- [Troubleshooting](#troubleshooting)

## Writing modules (C++)

A module is a class derived from `nativebind::Module` whose body starts with
`NATIVEBIND_MODULE`. Each feature is usually one `.cpp` file; several modules
may share a file.

### Declarations

| Macro | Declares | In Dart |
|---|---|---|
| `NATIVEBIND_MODULE(Name)` | a singleton, created when nativebind starts | `Name.instance` |
| `NATIVEBIND_MODULE(Name, .instanced = true)` | any number of instances, created by C++ | `Name.instances`, `Name.byKey(k)` |
| `NATIVEBIND_PROP(T, name, initial[, meta...])` | a property the UI may read and write | `BoundProperty<T>` |
| `NATIVEBIND_READ(T, name, initial[, meta...])` | a property the UI may only read | `BoundValue<T>` |
| `NATIVEBIND_LIST(T, name)` | an observable list | `BoundList<T>` |
| `NATIVEBIND_SIGNAL(name, Args...)` | an event with zero or more arguments | `BoundSignal<T>` (a `Stream`) |
| `NATIVEBIND_INVOKE` | a method the UI may call | `Future<R> name(...)` |
| `NATIVEBIND_INVOKE_AS(permission)` | a method the [guard](#access-control) must allow | `Future<R> name(...)` |
| `NATIVEBIND_DART_LIBRARY("package:x/x.dart")` | in a header: its types' Dart classes come from that library ([shared types](#extending-nativebind)) | imported |

`NATIVEBIND_MODULE` takes options: `.instanced = true` (see
[Instanced modules](#instanced-modules)) and `.order = n` (see
[Extending](#extending-nativebind)).

Doc comments (`///`) on modules, members and enumerators are copied to the
generated Dart and are also available at run time (`value.doc`), which makes
them handy as help text.

### Types

| C++ | Dart |
|---|---|
| `bool` | `bool` |
| `int8_t` ... `int64_t`, `uint8_t` ... `uint64_t`, `size_t`, ... | `int` (signed 64-bit) |
| `float`, `double` | `double` |
| `std::string` (`std::string_view` for parameters) | `String` |
| `enum` / `enum class` (values may be constant expressions) | enhanced `enum` with a `wire` value and a `label` (from `///< @label ...` or the name) |
| `struct` of supported types (public fields, no bases) | immutable class with `copyWith`, `==`, `hashCode`, defaults from the C++ initializers |
| `std::vector<T>` | `List<T>` |
| `std::optional<T>` | `T?` |
| `std::chrono::system_clock::time_point` | `DateTime` |
| `std::chrono::duration` (`seconds`, `milliseconds`, ...) | `Duration` |

A type can take another Dart name with `/// @dart Name` in its doc comment
(say, `Color` → `LedColor`, to stay clear of Flutter's `Color`); see [Names in Dart](#names-in-dart).

Aliases (`using`, `typedef`), namespaces and nested types are understood, and
types from local headers get their own Dart file. Give
structs `bool operator==(const T&) const = default;` so nativebind can skip
updates that change nothing.

Enums cross as 32-bit values, and a value must be one of the declared
enumerators: Dart cannot represent anything else, so it reports the record
and keeps the last good value. Use an integer property for bit flags
(`A | B`) or raw device values (`static_cast<Mode>(reg)`).

```cpp
enum class PlayState { Stopped, Playing, Paused };

/// One entry of the play queue.
struct Track {
    int32_t id = 0;
    std::string title;
    std::chrono::seconds length{0};
    bool liked = false;

    bool operator==(const Track&) const = default;
};
```

### Properties

```cpp
NATIVEBIND_PROP(double, volume, 0.5, .min = 0, .max = 1, .step = 0.05, .label = "Volume")
NATIVEBIND_READ(PlayState, state, PlayState::Stopped)
```

Metadata comes after the initial value, in this order:

| Field | Meaning |
|---|---|
| `.min`, `.max` | range for UI writes (clamped); values set by C++ are never clamped |
| `.step` | UI increment; 0 = continuous |
| `.label` | display name (default: derived from the member name) |
| `.attrs` | free-form key/value pairs for your own layers (see [Extending](#extending-nativebind)) |

A `Prop<T>` behaves like a thread-safe `T`:

```cpp
position = 12.5;               // set: Flutter is updated (coalesced)
double v = volume;             // get
volume.set(0.2);               // returns true if it changed
a = b;                         // copies b's value, never the property itself
```

Metadata can change at run time and Flutter follows:

```cpp
volume.setRange(0, 0.8);       // e.g. a limit that depends on the hardware
volume.setStep(0.1);
volume.setEnabled(false);      // shown disabled; UI writes are refused
```

UI writes go through three stages:

1. When the write arrives, the runtime checks that the property is writable
   and enabled and asks the guard; a refusal fails the write at once in Dart.
   On the nativebind thread it checks `enabled` again and clamps the value to
   `[min, max]` as they are then, so metadata C++ changed in the meantime
   applies.
2. `validate(fn)` may accept (`true`), reject (`false`), or replace the value
   (return a `T`, or a `std::optional<T>` that is `nullopt` to reject).
3. `onWrite(fn)` runs after the value is stored. It is not called for changes
   made by C++.

```cpp
Player() {
    volume.validate([](double v) { return std::round(v * 20) / 20; });  // snap to 5 % steps
    volume.onWrite([this](double v) { mixer_.setGain(v); });
}
```

Every write is acknowledged, even a rejected one, so a slider that was moved
to a refused value snaps back.

### Lists

```cpp
NATIVEBIND_LIST(Track, queue)

queue.push_back(track);
queue.insert(0, track);
queue.erase(i);
queue.eraseIf([](const Track& t) { return t.liked; });
queue.set(i, track);
queue.update(i, [](Track& t) { t.liked = !t.liked; });   // edit in place
queue.move(from, to);
queue.assign(tracks);                                     // replace all (one reset)
queue.sync(tracks, [](const Track& t) { return t.id; });  // minimal diff by key
auto i = queue.findIndex([&](const Track& t) { return t.id == id; });
```

Each operation reaches Flutter as one incremental change. Prefer `sync` over
`assign` when refreshing from a data source: rows keep their identity, so
animations and scroll positions survive. Lists are read-only in Dart; change
them through `NATIVEBIND_INVOKE` methods, which keeps the model in C++.
`sync` takes O(n log n) time when the key has a `std::hash` (strings,
integers), so even 5,000 shuffled rows take a few milliseconds. A key type
with only `==` falls back to O(n × m).

### Signals

```cpp
NATIVEBIND_SIGNAL(trackChanged, std::string)
NATIVEBIND_SIGNAL(finished)                     // no arguments

trackChanged("Intro");                          // from any thread
auto id = trackChanged.connect([](const std::string& t) { log(t); });   // C++ listeners too
trackChanged.disconnect(id);
player.trackChanged.connect(*this, [this](const std::string& t) { show(t); });  // ends with *this
```

Signals are for events without a current value ("track ended", "login
failed"). For state, use a property. Flutter receives every signal emitted
while it is attached, including those from `onStart`; signals emitted while
no isolate is attached are not kept.

C++ listeners run on the emitting thread. When a listener uses another
module, pass that module to `connect`: the connection then ends when the
module is destroyed (after its `onStop`), whichever of the two goes first.
`disconnect` returns only once the listener is no longer running on another
thread, so a listener must not wait for the thread that disconnects it.

### Methods

```cpp
NATIVEBIND_INVOKE int32_t add(std::string title, std::string artist, int32_t seconds);
NATIVEBIND_INVOKE void seek(double seconds);
```

Arguments and results may be any supported type. Methods run on the nativebind
thread. If one throws, the Dart `Future` completes with a
`BindInvokeException` carrying the message. Methods cannot be overloaded, and
C++ default arguments become required parameters in Dart.

### Lifecycle

```cpp
class Player : public nativebind::Module {
    NATIVEBIND_MODULE(Player)
public:
    Player() { /* initial values, setRange/setEnabled, validate/onWrite, Batch */ }
protected:
    void onStart() override {   // every singleton exists now
        every(100ms, [this] { tick(); });
    }
    void onStop() override { /* stop workers, release devices */ }
};
```

| Where | What belongs there |
|---|---|
| constructor | initial values, metadata, `validate`/`onWrite` handlers. All of it arrives in Flutter as the initial state. |
| `onStart()` | anything that needs other modules (`property<T>`, `singleton<T>`, typed references) and timers |
| `onStop()` | stopping workers, closing devices |

If the app exits without calling `NativeBind.stop()` (or `nativebind::stop()`
in a native host), the runtime stops from an exit handler registered when it
started. `onStop` then runs before the static objects that existed by the end
of `start()` (including what modules set up in `onStart`) are destroyed, but
after those first used later. Calling `NativeBind.stop()` before exiting, for
example from an `AppLifecycleListener`'s `onExitRequested`, avoids that limit.

Timers and posting, all on the nativebind thread and cancelled automatically
when the module is destroyed:

```cpp
auto id = every(1s, [this] { poll(); });
after(500ms, [this] { timeout(); });
cancel(id);
post([this] { later(); });       // from any thread
```

### Instanced modules

```cpp
class Download : public nativebind::Module {
    NATIVEBIND_MODULE(Download, .instanced = true)
public:
    NATIVEBIND_READ(std::string, name, "")
    NATIVEBIND_READ(double, progress, 0.0)
    Download(std::string fileName, int64_t bytes);
};

// Anywhere in C++ (any thread):
Download& d = nativebind::spawn<Download>(key, "file.bin", 1 << 20);  // key: unique per type
nativebind::destroy(d);                                              // async; onStop runs first
for (Download* d : nativebind::instances<Download>()) { ... }        // on the nativebind thread
```

In Dart, `Download.instances` is a `ValueListenable<List<Download>>` ordered by
key, and `Download.byKey(k)` finds one. Keys are `uint64_t`; one at or above
2^63 is a negative Dart `int` with the same 64 bits, and is still ordered last.

### Reaching other modules

Modules do not need headers to talk to each other. By name, checked at run
time:

```cpp
void onStart() override {
    volume_ = &nativebind::property<double>("Player", "volume");   // throws on a typo or wrong type
    auto& downloads = nativebind::singleton<Downloads>();          // if the type is visible
}
```

Or typed: the generator also writes `<module>.nb.hpp` next to the glue, with
references to every property and list:

```cpp
#include "player.nb.hpp"

void onStart() override {
    auto player = nativebind::ref::Player::get();   // singleton; ::get(key) for instances
    double v = player.volume;
}
```

Members whose type is declared inside the other module's `.cpp` are left out
of its `.nb.hpp`; move shared types into a header to reach them.

## Using modules (Dart)

### Values

Every property is a `ValueListenable` that notifies when its value or its
metadata changes:

| Member | |
|---|---|
| `value` | current value; for writable properties includes a pending write |
| `meta` | `min`, `max`, `step`, `label`, `writable`, `enabled`, `attrs`, live from C++ |
| `doc` | the C++ doc comment |
| `choices` | all values of an enum or bool property, for pickers |
| `hasValue`, `isAlive` | the first value arrived; the instance still exists in C++ |

```dart
ListenableBuilder(
  listenable: Listenable.merge([player.title, player.state, player.position]),
  builder: (context, _) => Text('${player.title.value} · ${player.state.value.label}'),
);
```

C++ changes are coalesced, and a whole batch is applied before any listener
runs, so widgets never see a half-updated state.

### Writes

```dart
player.volume.value = 0.8;                       // optimistic: shows at once
final kept = await player.volume.write(2);       // what C++ kept: 1.0 (clamped)
player.volume.isPending;                         // true until C++ acknowledged it
if (!player.volume.canWrite) ...                 // read-only, disabled or refused by the guard
player.volume.whyNotWritable;                    // the reason, as a BindException
```

Writes are sequence-numbered. Flutter shows the written value until C++
acknowledges that write, then shows whatever C++ decided.

For dragging, open an edit session. While it is open, incoming values do not
move the control, and writes are throttled (10 per second by default):

```dart
Slider(
  value: volume,
  onChangeStart: (_) => edit = player.volume.beginEdit(),
  onChanged: (v) => edit?.update(v),             // shown now, sent at most every 100 ms
  onChangeEnd: (v) { edit?.commit(v); edit = null; },
);
```

### Lists, signals, methods

```dart
ListView(children: [for (final t in player.queue) TrackTile(t)]);   // BoundList is a List
player.queue.changes.listen((c) => ...);    // ListInserted/Removed/Updated/Moved/Reset, for AnimatedList
player.trackChanged.listen((title) => ...); // BoundSignal is a broadcast Stream
final id = await player.add('Intro', 'Me', 90);
```

### Instances

```dart
ValueListenableBuilder(
  valueListenable: Download.instances,      // ordered by key
  builder: (context, list, _) => ListView(children: [for (final d in list) DownloadTile(d)]),
);
Download.byKey(3)?.progress;
download.isAlive;                           // false once C++ destroyed it
```

### Generic UIs

`module.$values` lists every property of a module, and each value carries its
`meta`, `doc` and `choices`. That is enough to build settings pages, parameter
lists or debug inspectors without naming each property.

### Errors

| Exception | When |
|---|---|
| `BindSchemaMismatch` | The generated Dart and the native library differ; the message shows the differing lines. Regenerate and rebuild. |
| `BindNotStarted` | `NativeBind.start` was not called, the library was not found, or a module is missing from it |
| `BindAccessDenied` | Refused by the guard (C++ or `NativeBind.writeGuard`) |
| `BindWriteRejected` | The property is read-only or disabled |
| `BindInvokeException` | The C++ method threw; carries its message |
| `BindInstanceGone` | The instance was destroyed in C++ |

### Finding the library

`NativeBind.start(library: 'libmy_backend.so')` searches, in order: the
directories in `NATIVEBIND_LIBRARY_PATH` (colon-separated), the system loader
path (`LD_LIBRARY_PATH`, `/usr/lib`, ...), and `lib/` next to the executable
(Flutter desktop bundles). A path containing `/` is opened as given. Under
flutter-pi the executable is flutter-pi itself, so install the library
system-wide or set `NATIVEBIND_LIBRARY_PATH`.

## Threads and background I/O

- UI writes, invokes, timers, `onStart` and `onStop` all run on the single
  **nativebind thread**, so module logic needs no locks.
- Properties, lists and signals are thread-safe and may be changed from any
  thread.
- Blocking I/O (sockets, serial ports, device drivers, slow files) must never
  run on the nativebind thread. Give the module a `nativebind::Worker`, a
  thread with a task queue and periodic jobs:

```cpp
class Download : public nativebind::Module {
    NATIVEBIND_MODULE(Download, .instanced = true)
public:
    NATIVEBIND_READ(int64_t, received, 0)
    NATIVEBIND_READ(double, progress, 0.0)
    NATIVEBIND_PROP(int32_t, speed, 512, .min = 64, .max = 4096)

    Download() {
        // UI writes arrive on the nativebind thread; hand them to the I/O thread.
        speed.onWrite([this](int32_t v) { io_.post([this, v] { socket_.setRate(v); }); });
    }
protected:
    void onStart() override { io_.every(100ms, [this] { transfer(); }); }
private:
    void transfer() {                          // on io_: blocking is fine here
        auto n = socket_.read(buffer_);
        nativebind::Batch batch;               // Flutter sees both or neither
        received = received + n;
        progress = double(received) / total_;
    }
    Socket socket_;                            // used only on io_
    nativebind::Worker io_{*this, "download"}; // stopped after onStop, before the rest goes away
};
```

| From a worker you may | Notes |
|---|---|
| set properties and metadata, change lists, emit signals | thread-safe |
| `post(fn)` to run module logic on the nativebind thread | for state shared with `NATIVEBIND_INVOKE` methods |
| open a `nativebind::Batch` to publish related values together | keep it short, never do I/O inside one |

| Don't | Instead |
|---|---|
| block the nativebind thread (I/O in `onWrite`, invokes, timers) | `io_.post(...)` |
| share plain members between a worker and the nativebind thread | a bound property, or `post` |
| let a worker outlive its module | give it its module, `Worker io_{*this, "name"}`, or `io_.stop()` in `onStop()` |

`Worker::sleepFor` returns early when the worker stops, for long loops.
Workers get thread names (visible in `top -H` and debuggers), and an exception
in a task is logged instead of killing the thread.

## Access control

A guard decides every UI write and every `NATIVEBIND_INVOKE_AS` call:

```cpp
enum class Role { Viewer, Operator, Admin };
std::atomic<Role> currentRole{Role::Viewer};

class Device : public nativebind::Module {
    NATIVEBIND_MODULE(Device)
public:
    NATIVEBIND_PROP(int32_t, brightness, 50, .min = 0, .max = 100, .attrs = {{"role", Role::Operator}})
    NATIVEBIND_INVOKE_AS(Role::Admin) void factoryReset();
};

nativebind::setGuard([](const nativebind::GuardRequest& r) -> std::string {
    int64_t need = r.permission;                                   // invokes: the INVOKE_AS argument
    if (r.meta)                                                    // writes: the property's metadata
        for (const auto& a : r.meta->attrs)
            if (a.key == "role") need = std::get<int64_t>(a.value.get());
    return int64_t(currentRole.load()) >= need ? "" : "requires a higher role";
});
```

The guard returns an empty string to allow, or the reason it refuses (Dart
gets a `BindAccessDenied` with it). It runs with no runtime lock held, so it
may read state from other modules (`nativebind::property<T>`, a typed
reference): for writes on the Flutter UI thread, for `NATIVEBIND_INVOKE_AS`
calls on the nativebind thread. Keep it fast, since the UI waits for it.
Without a guard, writes are allowed and `NATIVEBIND_INVOKE_AS` methods are
refused: it fails closed.

To let the UI show a lock or ask for a login *before* a write fails, mirror the
policy in Dart:

```dart
NativeBind.writeGuard = (property) =>
    (property.meta.attr<int>('role') ?? 0) > currentRole ? const BindAccessDenied('log in first') : null;
```

`BoundProperty.canWrite` and `whyNotWritable` take it into account. C++ always
has the final word.

## Extending nativebind

nativebind has no domain concepts. Libraries built on it (for display units,
user roles, data quality, event logs, ...) use four generic hooks:

- **Attributes.** `Meta::attrs` carries any key to a bool, integer (or enum),
  double or string. nativebind sends them to Dart unchanged, where
  `meta.attrs` and `meta.attr<T>(key)` read them. Wrap them in your own helpers
  and Dart extension getters:

  ```cpp
  NATIVEBIND_READ(double, pressure, 0.0, .attrs = {{"unit", "kPa"}, {"decimals", 1}})
  ```
  ```dart
  extension on PropertyMeta {
    String get unit => attr<String>('unit') ?? '';
  }
  ```

- **The guard**, described [above](#access-control), with `NativeBind.writeGuard`
  as its Dart mirror.
- **Module order.** `NATIVEBIND_MODULE(Name, .order = -100)` creates a singleton
  before the others and destroys it after them, for infrastructure (a session,
  a log, a settings store) that other modules use while starting and stopping.
- **Shared Dart types.** A header that declares
  `NATIVEBIND_DART_LIBRARY("package:my_lib/my_lib.dart")` has its enums and
  structs imported from that Dart library in apps' generated code instead of
  being generated again. A Dart package ships such headers in
  `<package>/native/include`; `dart run nativebind_generator` finds that
  directory in every dependency, and CMake builds register it with
  `nativebind_add_header_dirs(...)`. The library generates its own copy with
  `--provides package:my_lib/my_lib.dart`.

## Testing

### C++ modules

A module is a plain object: construct it and test its logic without the
runtime or Flutter. For tests that need the runtime, call
`nativebind::start()` and `nativebind::stop()` yourself;
`nativebind::flush()` waits until everything posted to the nativebind thread
has run.

### Views against a scripted native side

`FakeNative` (from `package:nativebind/testing.dart`) stands in for the
library. You script change-feed records exactly as C++ would send them, and
inspect the writes and invokes the UI made. Members are addressed by
declaration index:

```dart
import 'package:nativebind/testing.dart';

testWidgets('shows the count', (tester) async {
  final native = FakeNative(nativebindModules);
  native.feed
    ..resync()
    ..added(1, native.idOf('Counter'))     // instance handle 1
    ..meta(1, 0, min: 1, max: 10)          // step
    ..prop(1, 0, i(2))
    ..meta(1, 1, writable: false)          // count
    ..prop(1, 1, i(41));
  native.publish();
  await NativeBind.start(native: native, modules: nativebindModules);

  await tester.pumpWidget(const MaterialApp(home: CounterPage()));
  expect(find.text('41'), findsOneWidget);

  await tester.tap(find.text('Add'));
  expect(native.invokes.single.index, 0);  // increment()
});
```

### Views against the real library

Build the library (the example's test runs CMake in `setUpAll`) and start
nativebind with its path. `testWidgets` runs in fake time while C++ runs in
real time, so:

- start nativebind and await C++ calls inside `tester.runAsync(...)`;
- after letting C++ run, call `NativeBind.instance.drainNow()` and `pump()`;
- don't `await` a `StreamSubscription.cancel()` of a signal in a widget test:
  it completes outside fake time and stalls the test;
- use `pump(duration)` rather than `pumpAndSettle` when something animates
  forever.

```dart
Future<void> run(WidgetTester tester, [int ms = 50]) async {
  await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
  NativeBind.instance.drainNow();
  await tester.pump();
}
```

`NativeBind` is a process-wide singleton: add `tearDown(NativeBind.stop)` to
every test file.

## Building with CMake

`nativebind_add_modules` generates the C++ glue at build time (again whenever a
module or a header it includes changes, through a Ninja/Make depfile),
compiles it, and links `nativebind::runtime` (an OBJECT library) into your
shared library. Unless you set `CXX_VISIBILITY_PRESET` yourself, it also hides
every symbol except the `nativebind_*` C functions. The generator reads headers
in the target's include directories (`target_include_directories`) as well as
in `INCLUDE_DIRS`.

```cmake
add_subdirectory(path/to/nativebind/native nativebind)
add_library(my_backend SHARED)
nativebind_add_modules(my_backend SOURCES modules/player.cpp modules/station.cpp)
```

[`examples/showcase/native/CMakeLists.txt`](../examples/showcase/native/CMakeLists.txt)
is a complete template: it finds the nativebind package through the app's
`.dart_tool/package_config.json`.

| CMake | |
|---|---|
| `nativebind_add_modules(<target> SOURCES ... [INCLUDE_DIRS ...] [PROVIDES <uri>] [OUTPUT_DIR <dir>])` | generate and compile the glue for these modules |
| `nativebind_add_header_dirs(<dir>...)` | header directories the generator reads for every target (for libraries built on nativebind) |
| `nativebind_dart_package_dir(<package> <var> [PROJECT <dir>])` | a Dart package's root from the app's `package_config.json` |
| `NATIVEBIND_DART_PROJECT` | the Flutter app, used to find `nativebind_generator` |
| `NATIVEBIND_GENERATOR` | a full generator command, e.g. a compiled executable for cross builds |
| `NATIVEBIND_BUILD_TESTS`, `NATIVEBIND_WERROR`, `NATIVEBIND_SANITIZE` | options for building the runtime on its own |

The generator has no package dependencies, so CMake runs it with a plain
`dart bin/nativebind_generator.dart`; no `pub get` is needed in the build
environment. Where no Dart SDK is available (cross-compiling SDKs), compile it
with `dart compile exe` and pass `-DNATIVEBIND_GENERATOR=/path/to/nativebind_generator`.

## The generator

```sh
dart run nativebind_generator                         # scan ./native, write lib/nativebind/
dart run nativebind_generator native/modules --dart-out lib/src/nativebind
dart run nativebind_generator --watch                 # regenerate on save
dart run nativebind_generator --check                 # CI: exit code 3 if anything is stale
dart run nativebind_generator -I third_party/include  # extra header directories
dart run nativebind_generator --help
```

It writes, per module file, `<module>.nb.dart` (typed view models, enums and
data classes) plus `nativebind_modules.dart`, which lists every module. CMake
writes the C++ side: `<module>.nb.cpp` (the glue) and `<module>.nb.hpp` (typed
references for other module files). Headers of packages you depend on
(`<package>/native/include`) are found through `.dart_tool/package_config.json`,
without `-I`.

### Names in Dart

Names follow Dart conventions: `play_time` → `playTime`, `FAST_FORWARD` and
`kFastForward` → `fastForward`. Reserved words get a trailing `_`, and so do
members that would clash with what every Dart object or module proxy already
has (`hashCode`, `runtimeType`, `toString`, `noSuchMethod`, `isAlive`): a
property named `isAlive` is `isAlive_` in Dart. Enum labels come from
`///< @label Text` on the enumerator, or are derived from its name
(`FastForward` → "Fast forward").

Dart has no namespaces, so every generated enum and struct needs a distinct
Dart name. Give one another name with `@dart` in its doc comment, for example
to avoid a Flutter type such as `Color` in app code that imports both:

```cpp
/// A color as the LED driver takes it.
/// @dart LedColor
struct Color { uint8_t r, g, b; };
```

A type whose Dart name would be one of the `dart:core` types the generated
code uses (`bool`, `int`, `double`, `num`, `String`, `List`, `DateTime`,
`Duration`, `Object`, `Future`, `Null`, `Never`) is an error, since it would
hide that type; rename it with `@dart`.

### Safety nets

The generator is a dependency-free Dart program with a purpose-built parser
for the `NATIVEBIND_*` declarations, not a C++ compiler. The generated glue
therefore asks the compiler to confirm what it read:

- A `static_assert` per property, list, struct field, signal and method checks
  the whole type the generator read (nested types included: the item type of
  a `std::vector`, the value of a `std::optional`, which enum or struct)
  against the real declaration, including method parameters and return types.
  One per enumerator checks its value.
- A structured binding over each struct fails to compile if the struct has a
  field the generator did not see.
- At run time, the library checks property names and order when a module is
  created.
- The Dart side compares the schema embedded in the Dart code with the one in
  the native library at startup, so stale generated code fails loudly instead
  of corrupting data.

Errors look like compiler diagnostics:

```
native/modules/player.cpp:14:17: error: unknown type `Mode` for property `mode`
  hint: define the enum or struct in this file or in a header it includes with #include "..."
```

### Limitations

- Preprocessor conditionals are not evaluated: members inside `#if` are always
  seen, and the run-time check reports the mismatch.
- Macro arguments split at top-level commas, so give types like
  `std::pair<int, int>` an alias first (the generator tells you).
- `NATIVEBIND_INVOKE` methods cannot be overloaded, and C++ default arguments
  are required parameters in Dart.

### Editor setup (clangd)

Module `.cpp` files are compiled only through their generated `.nb.cpp`, so
`compile_commands.json` has no entry for them. clangd then falls back to a
guess without the include paths; add the flags in a `.clangd` file next to the
modules:

```yaml
CompileFlags:
  Add: [-std=c++20, -I/path/to/nativebind/native/include]
```

## Troubleshooting

**`BindNotStarted: cannot load the native library`.** The message lists every
path tried and the system loader's reason for each: a missing dependency, an
undefined symbol or the wrong architecture. See
[Finding the library](#finding-the-library) for the search order, or set
`NATIVEBIND_LIBRARY_PATH`. A library that loads but has no nativebind C ABI
(it was linked without `nativebind_add_modules`) is reported as such.

**`BindSchemaMismatch`.** The generated Dart and the native library were
generated from different C++ sources; the message shows the differing lines.
Run `dart run nativebind_generator` and rebuild the native library.

**"while applying native changes (the record was skipped)".** Dart could not
decode a change from C++, most often an enum value that is not one of the
declared enumerators (see [Types](#types)). The rest of the batch still
applies, and the member keeps its last good value.

**A `static_assert` in a `.nb.cpp`: "nativebind_generator read Player::seek
as void(int); please report this".** The generator read a declaration
differently from the compiler, for example through a macro it cannot see
through. Give the type an alias or move it out of the macro; if the
declaration is plain C++, please report it.

**C++ messages.** The runtime logs failures (a throwing `onStart`, a feed
overflow, a dropped write) to stderr with a `[nativebind]` prefix. Send them
elsewhere with `nativebind::setLogHandler`.
