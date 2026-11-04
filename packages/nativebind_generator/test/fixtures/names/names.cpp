// Names that collide with Dart: members of ModuleProxy and Object, enum
// members, keywords, and a type renamed away from dart:core. The generated
// Dart (packages/nativebind/test/generated/names) must compile.

#include <chrono>
#include <cstdint>
#include <string>

#include <nativebind/nativebind.hpp>

enum class Mode { values, index, name, is, in, late, with, super };

/// A span in device ticks; `Duration` is dart:core's in Dart.
/// @dart DeviceDuration
struct Duration {
    int32_t ticks = 0;
};

struct Pt {
    int32_t hashCode = 0;
    double x = 0;
};

class Names : public nativebind::Module {
    NATIVEBIND_MODULE(Names)
public:
    NATIVEBIND_PROP(int32_t, isAlive, 0)  ///< a heartbeat counter, not ModuleProxy.isAlive
    NATIVEBIND_PROP(int32_t, hashCode, 0)
    NATIVEBIND_READ(Mode, runtimeType, Mode::values)
    NATIVEBIND_READ(Pt, pt, {})
    NATIVEBIND_READ(Duration, span, {})
    NATIVEBIND_READ(std::chrono::milliseconds, timeout, {})
    NATIVEBIND_SIGNAL(noSuchMethod, int32_t)

    NATIVEBIND_INVOKE int32_t toString() { return 0; }
    NATIVEBIND_INVOKE Duration twice(Duration d) { return Duration{d.ticks * 2}; }
};
