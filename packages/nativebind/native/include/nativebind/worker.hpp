#pragma once
// Background threads for blocking I/O (serial ports, sockets, device drivers) and
// atomic groups of changes.

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>

#include "nativebind/property.hpp"

namespace nativebind {

/// A background thread with its own task queue and periodic jobs. Tasks run
/// one at a time, in order, so state used only by the worker needs no locks.
///
///     class Weather : public nativebind::Module {
///         ...
///     protected:
///         void onStart() override {
///             io_.every(500ms, [this] { poll(); });          // blocking reads
///         }
///     private:
///         void poll() {
///             auto r = station_.read();                      // may block for 100 ms
///             nativebind::Batch batch;                       // Flutter sees all or none
///             pressure = r.pressure;
///             humidity = r.humidity;
///         }
///         SerialStation station_;                  // used only on io_
///         nativebind::Worker io_{*this, "weather-io"}; // stops after onStop
///     };
///
/// Rules of thumb:
/// - Bound members (props, lists, signals) may be used from the worker directly.
/// - Other module state shared with the nativebind thread: hand it over with
///   Module::post() (to the nativebind thread) or Worker::post() (to the worker).
/// - UI writes arrive on the nativebind thread; forward them with
///   `interval.onWrite([this](int v) { io_.post([this, v] { station_.configure(v); }); });`
class Worker {
public:
    using Clock = std::chrono::steady_clock;

    /// [name] shows up in `top -H` and debuggers (max 15 characters on Linux).
    explicit Worker(std::string name = "nativebind-worker");
    /// A worker owned by a module: the runtime stops it after the module's
    /// onStop and before the module is deleted, wherever it is declared.
    /// Once stopped that way it accepts no more work (post and every are
    /// ignored), so a late post cannot restart I/O on closed resources.
    Worker(Module& owner, std::string name);
    /// Stops and joins the thread.
    ~Worker();

    Worker(const Worker&) = delete;
    Worker& operator=(const Worker&) = delete;

    /// Starts the thread (also done by the first post/every). Idempotent.
    /// Does nothing once the owner module ended.
    void start();
    /// Stops accepting work, lets the current task finish, joins the thread and
    /// drops queued tasks. Idempotent; must not be called from the worker itself.
    /// An unowned worker restarts on the next post/every.
    void stop();
    bool running() const;
    /// True on this worker's thread.
    bool onThread() const noexcept;

    /// Runs [task] on the worker after the tasks queued before it.
    void post(std::function<void()> task);
    /// Runs [task] every [period] (first run after [period], or now with
    /// [runNow]). Returns an id for cancel().
    uint64_t every(std::chrono::milliseconds period, std::function<void()> task, bool runNow = false);
    void cancel(uint64_t id);

    /// For long-running tasks: sleeps up to [d]; returns false (early) once
    /// stop() was called, so loops can exit promptly.
    bool sleepFor(std::chrono::milliseconds d);
    /// True once stop() was called.
    bool stopping() const noexcept { return stopping_.load(); }

    const std::string& name() const noexcept { return name_; }

private:
    void run();

    struct Periodic {
        Clock::time_point due;
        std::chrono::milliseconds period;
        std::shared_ptr<std::function<void()>> task;
    };

    const std::string name_;
    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::deque<std::function<void()>> tasks_;
    std::map<uint64_t, Periodic> periodic_;
    uint64_t nextId_ = 1;
    std::thread thread_;
    std::atomic<std::thread::id> threadId_{};
    std::atomic<bool> stopping_{false};
    bool running_ = false;
    bool ended_ = false;  // the owner module ended: no more work
    Module* owner_ = nullptr;
    uint64_t ownerEnd_ = 0;
};

/// Groups changes so Flutter applies them together: while any Batch is alive
/// the change feed is not read, so the UI never sees half of an update (e.g.
/// a new reading with an old timestamp). The UI thread never waits for a
/// batch; it picks the changes up when the last open batch closes. Nests;
/// works on any thread. Keep batches short: they hold back UI updates (from
/// every module). Never do I/O inside one.
///
///     {
///         nativebind::Batch batch;
///         received = r;
///         total = t;
///         progress = double(r) / t;
///     }
class Batch {
public:
    Batch();
    ~Batch();
    Batch(const Batch&) = delete;
    Batch& operator=(const Batch&) = delete;
};

/// Runs [fn] inside a Batch.
template <class F>
void batch(F&& fn) {
    Batch b;
    fn();
}

namespace detail {
PropBase& findProperty(std::string_view module, std::string_view prop, uint64_t key);
}

/// Another module's property by name, so single-file modules can read each
/// other without headers: `nativebind::property<double>("Player", "volume")`.
/// For instanced modules pass the key. Throws std::logic_error if the module,
/// the property or its type does not match. The reference stays valid while
/// that module is alive (for singletons: until nativebind stops).
template <class T>
Prop<T>& property(std::string_view module, std::string_view prop, uint64_t key = 0) {
    PropBase& p = detail::findProperty(module, prop, key);
    auto* typed = dynamic_cast<Prop<T>*>(&p);
    if (!typed) {
        throw std::logic_error(std::string("nativebind::property: ") + std::string(module) + "." + std::string(prop) +
                               " has a different type");
    }
    return *typed;
}

}  // namespace nativebind
