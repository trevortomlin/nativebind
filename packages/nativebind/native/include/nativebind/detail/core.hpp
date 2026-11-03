#pragma once
// Internal hooks between bound members and the runtime. Not part of the public
// API; used by the member templates in property.hpp, list.hpp and signal.hpp.

#include <chrono>
#include <cstdint>
#include <functional>

#include "nativebind/codec.hpp"

namespace nativebind {

class Module;
class PropBase;
using TimerId = uint64_t;

namespace detail {

/// Record kinds of the change feed (doc/wire-format.md).
enum class Rec : uint8_t {
    Resync = 1,
    InstanceAdded = 2,
    InstanceRemoved = 3,
    Prop = 4,
    Meta = 5,
    ListReset = 6,
    ListInsert = 7,
    ListRemove = 8,
    ListUpdate = 9,
    ListMove = 10,
    Signal = 11,
    Result = 12,
};

/// Writes one framed record: u8 kind, u32 payload length, payload.
template <class F>
void writeRecord(Writer& w, Rec kind, const F& body) {
    w.u8(static_cast<uint8_t>(kind));
    const size_t at = w.size();
    w.u32(0);
    body(w);
    w.patchU32(at, static_cast<uint32_t>(w.size() - at - 4));
}

using BuildFn = void (*)(Writer&, const void*);

/// Appends a record to the ordered event queue (lists, signals, instances).
void enqueueEvent(Rec kind, BuildFn build, const void* ctx);

template <class F>
void event(Rec kind, const F& body) {
    enqueueEvent(kind, [](Writer& w, const void* c) { (*static_cast<const F*>(c))(w); }, &body);
}

void propChanged(PropBase& p);
void metaChanged(PropBase& p);

/// Runs fn on the nativebind thread if the module is still alive then, otherwise
/// runs `dropped` (if any) instead.
void postFor(uint32_t handle, std::function<void()> fn, std::function<void()> dropped = {});

uint32_t newHandle() noexcept;
TimerId newTimerId() noexcept;
void armTimer(Module& owner, TimerId id, std::chrono::milliseconds delay, std::chrono::milliseconds period,
              std::function<void()> fn);
void cancelTimer(TimerId id);
void moduleGone(uint32_t handle) noexcept;

void logf(const char* fmt, ...) __attribute__((format(printf, 1, 2)));

}  // namespace detail
}  // namespace nativebind
