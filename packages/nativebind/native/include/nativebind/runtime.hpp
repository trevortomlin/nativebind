#pragma once
// Runtime API for module code: instances, cross-module access, the nativebind
// thread. In a Flutter app the runtime is started by the Dart side; native
// hosts and tests call nativebind::start() themselves.

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <functional>
#include <memory>
#include <type_traits>
#include <typeinfo>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "nativebind/module.hpp"
#include "nativebind/types.hpp"

namespace nativebind {

namespace detail {
Module& adopt(const std::type_info& type, std::unique_ptr<Module> module, uint64_t key);
Module& singleton(const std::type_info& type);
std::vector<Module*> instances(const std::type_info& type);
void destroy(uint32_t handle);
}  // namespace detail

/// Starts the runtime: starts the nativebind thread, creates every singleton and
/// calls their onStart. Idempotent.
void start();
/// Calls onStop on every module (newest first), destroys them and stops the
/// nativebind thread. Idempotent.
void stop();
bool started() noexcept;
/// Waits until everything posted to the nativebind thread so far has run.
bool flush(std::chrono::milliseconds timeout = std::chrono::seconds(5));

/// Runs fn on the nativebind thread.
void post(std::function<void()> fn);
bool onNativeBindThread() noexcept;

/// Creates an instance of an instanced module (NATIVEBIND_MODULE(T, .instanced = true)).
/// `key` identifies it from Flutter (`Download.byKey(3)`) and must be unique per
/// type. Callable from any thread; onStart runs on the nativebind thread. The
/// runtime owns the instance until nativebind::destroy. Throws std::logic_error
/// if the runtime is not started or is stopping (e.g. when called from onStop).
template <class T, class... A>
T& spawn(uint64_t key, A&&... args) {
    static_assert(std::is_base_of_v<Module, T>, "spawn<T>: T must derive from nativebind::Module");
    auto module = std::make_unique<T>(std::forward<A>(args)...);
    T& ref = *module;
    detail::adopt(typeid(T), std::move(module), key);
    return ref;
}

/// Destroys a spawned instance (asynchronously, on the nativebind thread, after onStop).
inline void destroy(Module& m) { detail::destroy(m.handle()); }

/// The singleton of module type T. Throws if the runtime is not started.
template <class T>
T& singleton() {
    return static_cast<T&>(detail::singleton(typeid(T)));
}

/// Live instances of T, ordered by key. Use on the nativebind thread.
template <class T>
std::vector<T*> instances() {
    std::vector<T*> out;
    for (Module* m : detail::instances(typeid(T))) out.push_back(static_cast<T*>(m));
    return out;
}

/// What the UI is attempting, for the Guard.
struct GuardRequest {
    enum class Kind { Write, Invoke };
    Kind kind;
    const char* module;  ///< module type name
    const char* member;  ///< property or method name
    const Meta* meta;    ///< the property's metadata (writes); null for invokes
    int64_t permission;  ///< the NATIVEBIND_INVOKE_AS argument (invokes); 0 for writes
};

/// Access policy for UI writes and invokes: returns an empty string to allow,
/// or the reason it is denied (Dart receives a BindAccessDenied with it).
///
/// It runs on the calling thread with the runtime locked, before every UI write
/// and every NATIVEBIND_INVOKE_AS call: keep it fast and only read state (an
/// atomic user role, say); never call nativebind from it.
using Guard = std::function<std::string(const GuardRequest&)>;

/// Installs the guard (one at a time; null removes it). stop() removes it.
/// Without a guard, writes are allowed and NATIVEBIND_INVOKE_AS methods are refused.
void setGuard(Guard guard);

/// When the UI last wrote, invoked or reported activity (see touchUiActivity).
std::chrono::steady_clock::time_point lastUiActivity() noexcept;
/// Records UI activity without a write, e.g. a touch on the screen.
void touchUiActivity() noexcept;

/// Writes a diagnostic message through the log handler (for libraries built
/// on nativebind).
void log(std::string_view message);

/// Receives runtime diagnostics (default: stderr).
using LogHandler = void (*)(const char* message);
void setLogHandler(LogHandler handler) noexcept;

}  // namespace nativebind
