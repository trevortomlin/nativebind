// The smallest useful module: a writable value, a read-only value, a signal
// and two methods. This file is all the C++ there is: no header, no FFI.

#include <nativebind/nativebind.hpp>

#include <cstdint>

/// Counts taps.
class Counter : public nativebind::Module {
    NATIVEBIND_MODULE(Counter)
public:
    /// How much each tap adds.
    NATIVEBIND_PROP(int32_t, step, 1, .min = 1, .max = 10)
    /// The current count.
    NATIVEBIND_READ(int64_t, count, 0)
    /// Sent each time the count passes a multiple of 10.
    NATIVEBIND_SIGNAL(milestone, int64_t)

    NATIVEBIND_INVOKE void increment() {
        const int64_t before = count;
        const int64_t after = before + step;
        count = after;  // assigning a bound value updates Flutter
        if (after / 10 > before / 10) milestone(after / 10 * 10);
    }

    NATIVEBIND_INVOKE void reset() { count = 0; }
};
