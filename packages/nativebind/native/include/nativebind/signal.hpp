#pragma once
// Bound signals: NATIVEBIND_SIGNAL. Events without a current value (e.g. "track
// ended", "login failed"). Flutter receives them as a Stream.

#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <utility>
#include <vector>

#include "nativebind/module.hpp"

namespace nativebind {

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
        std::vector<std::shared_ptr<Listener>> listeners;
        {
            std::lock_guard g(mutex_);
            listeners.reserve(listeners_.size());
            for (const auto& entry : listeners_) listeners.push_back(entry.second);
        }
        for (const auto& l : listeners) (*l)(args...);
    }

    /// Adds a C++ listener; returns an id for disconnect().
    uint64_t connect(Listener fn) {
        std::lock_guard g(mutex_);
        listeners_.emplace_back(++nextId_, std::make_shared<Listener>(std::move(fn)));
        return nextId_;
    }
    void disconnect(uint64_t id) {
        std::lock_guard g(mutex_);
        std::erase_if(listeners_, [id](const auto& p) { return p.first == id; });
    }

private:
    mutable std::mutex mutex_;
    std::vector<std::pair<uint64_t, std::shared_ptr<Listener>>> listeners_;
    uint64_t nextId_ = 0;
};

}  // namespace nativebind
