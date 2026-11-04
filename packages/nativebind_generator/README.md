# nativebind_generator

Reads nativebind modules written in C++ and generates:

- `<module>.nb.cpp`: the FFI glue, compiled into your native library (CMake runs
  this at build time).
- `<module>.nb.hpp`: typed references (`nativebind::ref::X::get()`) for other
  module files.
- `<module>.nb.dart`: typed Dart view models, enums and data classes, plus
  `nativebind_modules.dart`, which lists every module.

You never write FFI code or bindings by hand. See the
[nativebind README](https://github.com/trevortomlin/nativebind#readme) for the
full guide.

## Usage

```sh
dart run nativebind_generator                         # scans ./native, writes lib/nativebind/
dart run nativebind_generator native/modules --dart-out lib/src/nativebind
dart run nativebind_generator --watch                 # regenerate on save
dart run nativebind_generator --check                 # CI: exit 3 if generated code is stale
dart run nativebind_generator -I third_party/include  # more header directories
dart run nativebind_generator --help
```

Headers of packages you depend on (`<package>/native/include`) are found
through `.dart_tool/package_config.json`, without `-I`.

C++ glue is produced by CMake through `nativebind_add_modules`:

```cmake
add_subdirectory(path/to/nativebind/native nativebind)
add_library(my_backend SHARED)
nativebind_add_modules(my_backend SOURCES modules/player.cpp modules/downloads.cpp)
```

The generator has no package dependencies, so CMake runs it with a plain
`dart bin/nativebind_generator.dart`; no `pub get` is needed in the build
environment. Changes to the module file or any header it includes regenerate the
glue (through a Ninja/Make depfile). Packages built on nativebind register their
header directories with `nativebind_add_header_dirs(...)`. Where no Dart SDK is
available (cross-compiling SDKs), compile the generator with `dart compile exe`
and pass `-DNATIVEBIND_GENERATOR=/path/to/nativebind_generator`.

## What it understands

```cpp
#include <nativebind/nativebind.hpp>
#include "media_types.hpp"          // types from local headers get their own Dart file

namespace media {

/// Doc comments are copied to Dart.
class Player : public nativebind::Module {
    NATIVEBIND_MODULE(Player)                     // or NATIVEBIND_MODULE(Download, .instanced = true)
public:
    enum class Repeat { Off, One, All };          // nested and namespaced types
    NATIVEBIND_PROP(Gain, volume, 0.5, .min = 0, .max = 1)            // aliases (using / typedef)
    NATIVEBIND_READ(std::optional<double>, play_time, std::nullopt)   // -> playTime (double?)
    NATIVEBIND_LIST(Track, queue)                 // -> BoundList<Track>
    NATIVEBIND_SIGNAL(failed, std::string, Repeat)                    // -> BoundSignal<(String, Repeat)>
    NATIVEBIND_INVOKE std::string describe(std::string_view prefix) const;   // -> Future<String>
    NATIVEBIND_INVOKE_AS(Role::Admin) void factoryReset();           // the guard decides
};

}
```

| C++ | Dart |
|---|---|
| `bool`, integers, `float`/`double`, `std::string` | `bool`, `int`, `double`, `String` |
| `enum` / `enum class` (values may be constant expressions) | enhanced `enum` with a `wire` value and a `label` |
| `struct` of supported types (public fields, no bases) | immutable class with `copyWith`, `==`, defaults from C++ initializers |
| `std::vector<T>`, `std::optional<T>` | `List<T>`, `T?` |
| `std::chrono::system_clock::time_point`, `std::chrono::duration` | `DateTime`, `Duration` |
| types from a header with `NATIVEBIND_DART_LIBRARY("package:x/x.dart")` | imported from that library (not generated again) |

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

## Safety nets

The generator reads C++ with a purpose-built parser, not a compiler. The
generated glue therefore asks the compiler to confirm what the parser read:

- A `static_assert` per property, list, struct field, signal and method checks
  the whole type the generator read (nested types included: the item type of
  a `std::vector`, the value of a `std::optional`, which enum or struct)
  against the real declaration, including method parameters and return types.
  One per enumerator checks its value.
- A structured binding over each struct fails to compile if the struct has a
  field the generator did not see.
- At runtime, the library checks property names and order when a module is
  created.
- The Dart side compares the schema embedded in the Dart code with the one in
  the native library at startup, so stale generated code fails loudly instead
  of corrupting data.

Errors look like compiler diagnostics:

```
native/player.cpp:14:17: error: unknown type `Mode` for property `mode`
  hint: define the enum or struct in this file or in a header it includes with #include "..."
```

## Limitations

- Preprocessor conditionals are not evaluated: members inside `#if` are always
  seen. The runtime check reports a mismatch.
- `NATIVEBIND_INVOKE` methods cannot be overloaded, and C++ default arguments are
  required parameters in Dart.
- Macro arguments split at commas, so name types like `std::pair<int, int>`
  with an alias first (the generator tells you).

## Development

```sh
dart test                                      # includes compiling generated glue with g++/clang++
NATIVEBIND_UPDATE_GOLDENS=1 dart test test/golden_test.dart
```

## License

MIT.
