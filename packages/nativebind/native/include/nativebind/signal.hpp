#pragma once
// Bound signals: NATIVEBIND_SIGNAL. Events without a current value (e.g. "track
// ended", "login failed"). Flutter receives them as a Stream.

#include <condition_variable>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <utility>
#include <vector>

#include "nativebind/module.hpp"

namespace nativebind {

namespace detail {

/// One connected listener. Calls count themselves in and out so that
/// disconnect can wait for the ones running on other threads.
struct ListenerSlot {
    std::mutex m;
    std::condition_variable idle;
    int running = 0;
    bool connected = true;
};

/// Marks a call of a listener on this thread; entered() is false if the
/// listener was disconnected meanwhile.
class ListenerCall {
public:
    explicit ListenerCall(ListenerSlot& s);
    ~ListenerCall();
    ListenerCall(const ListenerCall&) = delete;
    ListenerCall& operator=(const ListenerCall&) = delete;
    bool entered() const noexcept { return entered_; }

private:
    ListenerSlot& slot_;
    bool entered_;
};

/// Stops new calls and waits for running ones, except those on this thread
/// (a listener disconnecting itself).
void retireListener(ListenerSlot& s);

}  // namespace detail

class SignalBase {
public:
    SignalBase(const SignalBase&) = delete;
    SignalBase& operator=(const SignalBase&) = delete;

    const char* name() const noexcept { return name_; }
    uint16_t index() const noexcept { return index_; }
    Module& owner() const noexcept { return *owner_; }

protected:
    SignalBase(Module* owner, const char* name);
    ~SignalBase() = default;

    /// Runs `disconnect` when `listener` is destroyed (after its onStop).
    static void endWith(Module& listener, std::function<void()> disconnect);

    Module* const owner_;
    const char* const name_;
    const uint16_t index_;
};

/// `trackChanged("Intro")` sends the event to Flutter and to C++ listeners added with
/// connect(). May be emitted from any thread; listeners run on that thread.
template <class... A>
class Signal final : public SignalBase {
public:
    using Listener = std::function<void(const A&...)>;

    Signal(Module* owner, const char* name) : SignalBase(owner, name) { (void)(tagOf<A>(), ...); }

    void operator()(const A&... args) const { emit(args...); }

    void emit(const A&... args) const {
        if (owner_->live()) {
            const uint32_t h = owner_->handle();
            const uint16_t i = index_;
            detail::event(detail::Rec::Signal, [&](Writer& w) {
                w.u32(h);
                w.u16(i);
                w.u8(static_cast<uint8_t>(sizeof...(A)));
                (w.value(args), ...);
            });
        }
        std::vector<std::shared_ptr<Entry>> listeners;
        {
            std::lock_guard g(core_->mutex);
            listeners.reserve(core_->entries.size());
            for (const auto& entry : core_->entries) listeners.push_back(entry.second);
        }
        for (const auto& l : listeners) {
            detail::ListenerCall call(*l);
            if (call.entered()) l->fn(args...);
        }
    }

    /// Adds a C++ listener; returns an id for disconnect().
    uint64_t connect(Listener fn) {
        std::lock_guard g(core_->mutex);
        core_->entries.emplace_back(++core_->nextId, std::make_shared<Entry>(std::move(fn)));
        return core_->nextId;
    }

    /// Adds a listener that is disconnected when `listener` (the module whose
    /// members fn uses) is destroyed, after its onStop. Use it whenever fn
    /// captures another module's `this`:
    ///
    ///     download.finished.connect(*this, [this] { post([this] { recount(); }); });
    ///
    /// Either module may be destroyed first.
    uint64_t connect(Module& listener, Listener fn) {
        const uint64_t id = connect(std::move(fn));
        endWith(listener, [core = std::weak_ptr<Core>(core_), id] {
            if (auto c = core.lock()) drop(*c, id);
        });
        return id;
    }

    /// Removes a listener. Returns once no call of it is running on another
    /// thread, so what it captured may be destroyed right after. A listener
    /// may disconnect itself.
    void disconnect(uint64_t id) { drop(*core_, id); }

private:
    struct Entry : detail::ListenerSlot {
        explicit Entry(Listener f) : fn(std::move(f)) {}
        Listener fn;
    };
    struct Core {
        std::mutex mutex;
        std::vector<std::pair<uint64_t, std::shared_ptr<Entry>>> entries;
        uint64_t nextId = 0;
    };

    static void drop(Core& c, uint64_t id) {
        std::shared_ptr<Entry> gone;
        {
            std::lock_guard g(c.mutex);
            for (auto it = c.entries.begin(); it != c.entries.end(); ++it)
                if (it->first == id) {
                    gone = std::move(it->second);
                    c.entries.erase(it);
                    break;
                }
        }
        if (gone) detail::retireListener(*gone);
    }

    // Shared so that a connection owned by another module can outlive the signal.
    std::shared_ptr<Core> core_ = std::make_shared<Core>();
};

}  // namespace nativebind
