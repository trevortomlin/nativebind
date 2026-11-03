#pragma once
// Base class of every bound module.

#include <atomic>
#include <chrono>
#include <cstdint>
#include <functional>
#include <vector>

#include "nativebind/detail/core.hpp"

namespace nativebind {

class ListBase;
class SignalBase;
namespace detail {
class Runtime;
}
namespace glue {
struct ModuleType;
}

/// Base class of a bound module. Derive from it and add NATIVEBIND_MODULE plus
/// bound members:
///
///     class Player : public nativebind::Module {
///         NATIVEBIND_MODULE(Player)
///     public:
///         NATIVEBIND_PROP(double, volume, 0.5, .min = 0, .max = 1, .step = 0.05)
///         NATIVEBIND_INVOKE void seek(double seconds);
///     };
///
/// Threading: UI writes, NATIVEBIND_INVOKE methods, timers, onStart and onStop all
/// run on the single nativebind thread, so module logic needs no locks. Bound
/// members (props, lists, signals) may also be changed from any other thread,
/// e.g. a device or network poller.
///
/// A module is a plain C++ object: it can be constructed and unit-tested
/// without the runtime. It is only visible to Flutter after the runtime adopts
/// it (singletons at nativebind::start(), instances via nativebind::spawn).
///
/// What goes where:
///   constructor  initial values, setRange/setStep/setEnabled/setMeta,
///                validate() and onWrite() handlers, nativebind::Batch. All of
///                this is safe and arrives in Flutter as the initial state.
///   onStart()    anything that needs other modules (nativebind::property,
///                singleton, instances, the generated nativebind::ref::X::get())
///                and timers (every/after): every singleton exists by now.
///   onStop()     stop Workers and release devices.
class Module {
public:
    Module(const Module&) = delete;
    Module& operator=(const Module&) = delete;
    virtual ~Module();

    /// Process-unique id of this instance; never reused.
    uint32_t handle() const noexcept { return handle_; }
    /// Key given to nativebind::spawn (0 for singletons).
    uint64_t key() const noexcept { return key_; }
    /// True while the runtime has the module (between adoption and destroy).
    bool live() const noexcept { return live_.load(std::memory_order_acquire); }

    /// Calls fn on the nativebind thread every `period`. Timers created before the
    /// module is live start when it goes live; all stop when it is destroyed.
    TimerId every(std::chrono::milliseconds period, std::function<void()> fn);
    /// Calls fn once on the nativebind thread after `delay`.
    TimerId after(std::chrono::milliseconds delay, std::function<void()> fn);
    void cancel(TimerId id);
    /// Runs fn on the nativebind thread (dropped if the module is destroyed first).
    void post(std::function<void()> fn);

protected:
    Module();

    /// Called on the nativebind thread once the module is live. For singletons,
    /// every singleton exists before the first onStart runs.
    virtual void onStart() {}
    /// Called on the nativebind thread before the module is destroyed.
    virtual void onStop() {}

private:
    friend class detail::Runtime;
    friend class PropBase;
    friend class ListBase;
    friend class SignalBase;

    std::vector<PropBase*> props_;
    std::vector<ListBase*> lists_;
    std::vector<SignalBase*> signals_;
    const uint32_t handle_;
    uint64_t key_ = 0;
    uint16_t typeId_ = 0;
    const glue::ModuleType* type_ = nullptr;
    std::atomic<bool> live_{false};
};

}  // namespace nativebind
