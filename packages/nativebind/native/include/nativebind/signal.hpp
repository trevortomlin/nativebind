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

    /// Runs `disconnect` when `listener` is destroyed (after its onStop);
    /// returns an id for unendWith.
    static uint64_t endWith(Module& listener, std::function<void()> disconnect);
    /// Forgets an endWith registration that has not run yet; never waits.
    static void unendWith(Module& listener, uint64_t id);

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
    uint64_t connect(Listener fn) { return add(std::move(fn)).first; }

    /// Adds a listener that is disconnected when `listener` (the module whose
    /// members fn uses) is destroyed, after its onStop. Use it whenever fn
    /// captures another module's `this`:
    ///
    ///     download.finished.connect(*this, [this] { post([this] { recount(); }); });
    ///
    /// Either module may be destroyed first.
    uint64_t connect(Module& listener, Listener fn) {
        auto [id, entry] = add(std::move(fn));
        const uint64_t end = endWith(listener, [core = std::weak_ptr<Core>(core_), e = std::weak_ptr<Entry>(entry), id] {
            if (auto en = e.lock()) {
                std::lock_guard g(en->ownerMutex);
                en->owner = nullptr;  // ending: disconnect must not unregister this
            }
            if (auto c = core.lock()) drop(*c, id);
        });
        {
            std::lock_guard g(entry->ownerMutex);
            if (!entry->dropped) {
                entry->owner = &listener;
                entry->end = end;
                return id;
            }
        }
        unendWith(listener, end);  // disconnected meanwhile, on another thread
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
        // A connection owned by a module: its endWith registration, removed on
        // disconnect. `owner` is cleared when that registration runs, so a
        // non-null owner is alive (its end waits for ownerMutex).
        std::mutex ownerMutex;
        Module* owner = nullptr;
        uint64_t end = 0;
        bool dropped = false;
    };
    struct Core {
        std::mutex mutex;
        std::vector<std::pair<uint64_t, std::shared_ptr<Entry>>> entries;
        uint64_t nextId = 0;
    };

    std::pair<uint64_t, std::shared_ptr<Entry>> add(Listener fn) {
        auto entry = std::make_shared<Entry>(std::move(fn));
        std::lock_guard g(core_->mutex);
        core_->entries.emplace_back(++core_->nextId, entry);
        return {core_->nextId, std::move(entry)};
    }

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
        if (!gone) return;
        {
            std::lock_guard g(gone->ownerMutex);
            gone->dropped = true;
            if (gone->owner) unendWith(*gone->owner, gone->end);
            gone->owner = nullptr;
        }
        detail::retireListener(*gone);
    }

    // Shared so that a connection owned by another module can outlive the signal.
    std::shared_ptr<Core> core_ = std::make_shared<Core>();
};

}  // namespace nativebind
