// Non-template parts of Module and the bound member classes.

#include <algorithm>
#include <variant>

#include "nativebind/list.hpp"
#include "nativebind/module.hpp"
#include "nativebind/property.hpp"
#include "nativebind/signal.hpp"

namespace nativebind {

// ------------------------------------------------------------------ Module

Module::Module() : handle_(detail::newHandle()) {}

Module::~Module() {
    endConnections();  // modules the runtime never adopted (it ends them in destroyNow)
    detail::moduleGone(handle_);
}

TimerId Module::every(std::chrono::milliseconds period, std::function<void()> fn) {
    if (period.count() <= 0) throw std::invalid_argument("nativebind::Module::every: period must be positive");
    const TimerId id = detail::newTimerId();
    detail::armTimer(*this, id, period, period, std::move(fn));
    return id;
}

TimerId Module::after(std::chrono::milliseconds delay, std::function<void()> fn) {
    const TimerId id = detail::newTimerId();
    detail::armTimer(*this, id, delay, std::chrono::milliseconds(0), std::move(fn));
    return id;
}

void Module::cancel(TimerId id) { detail::cancelTimer(id); }

void Module::post(std::function<void()> fn) { detail::postFor(handle_, std::move(fn)); }

// ------------------------------------------------------------------ PropBase

PropBase::PropBase(Module* owner, const char* name, const Meta& meta, bool writable)
    : meta_(meta),
      owner_(owner),
      name_(name),
      index_(static_cast<uint16_t>(owner->props_.size())),
      writable_(writable) {
    owner->props_.push_back(this);
}

Meta PropBase::meta() const {
    std::lock_guard g(mutex_);
    return meta_;
}

void PropBase::setMeta(const Meta& m) {
    {
        std::lock_guard g(mutex_);
        meta_ = m;
    }
    detail::metaChanged(*this);
}

void PropBase::setRange(double min, double max) {
    {
        std::lock_guard g(mutex_);
        if (meta_.min == min && meta_.max == max) return;
        meta_.min = min;
        meta_.max = max;
    }
    detail::metaChanged(*this);
}

void PropBase::setStep(double step) {
    {
        std::lock_guard g(mutex_);
        if (meta_.step == step) return;
        meta_.step = step;
    }
    detail::metaChanged(*this);
}

bool PropBase::enabled() const {
    std::lock_guard g(mutex_);
    return enabled_;
}

void PropBase::setEnabled(bool enabled) {
    {
        std::lock_guard g(mutex_);
        if (enabled_ == enabled) return;
        enabled_ = enabled;
    }
    detail::metaChanged(*this);
}

void PropBase::encodeState(Writer& w) const {
    std::lock_guard g(mutex_);
    w.u32(ackSeq_);
    encodeValueLocked(w);
}

void PropBase::encodeMeta(Writer& w) const {
    std::lock_guard g(mutex_);
    w.f64(meta_.min);
    w.f64(meta_.max);
    w.f64(meta_.step);
    uint8_t flags = 0;
    if (writable_) flags |= 1;
    if (enabled_) flags |= 2;
    w.u8(flags);
    w.str(meta_.label);
    w.u16(static_cast<uint16_t>(meta_.attrs.size()));
    for (const Attr& a : meta_.attrs) {
        w.str(a.key);
        std::visit([&w](const auto& v) { w.value(v); }, a.value.get());
    }
}

// ------------------------------------------------------------------ ListBase

ListBase::ListBase(Module* owner, const char* name)
    : owner_(owner), name_(name), index_(static_cast<uint16_t>(owner->lists_.size())) {
    owner->lists_.push_back(this);
}

void ListBase::goLive() {
    std::lock_guard g(mutex_);
    live_ = true;
    emitResetLocked();
}

void ListBase::goDead() {
    std::lock_guard g(mutex_);
    live_ = false;
}

void ListBase::encodeReset(Writer& w) const {
    std::lock_guard g(mutex_);
    w.u32(owner_->handle());
    w.u16(index_);
    w.u32(version_);
    encodeItemsLocked(w);
}

// ------------------------------------------------------------------ SignalBase

SignalBase::SignalBase(Module* owner, const char* name)
    : owner_(owner), name_(name), index_(static_cast<uint16_t>(owner->signals_.size())) {
    owner->signals_.push_back(this);
}

void SignalBase::endWith(Module& listener, std::function<void()> disconnect) {
    std::lock_guard g(listener.connectionsMutex_);
    listener.connections_.push_back(std::move(disconnect));
}

void Module::endConnections() {
    std::vector<std::function<void()>> ends;
    {
        std::lock_guard g(connectionsMutex_);
        ends.swap(connections_);
    }
    for (auto& end : ends) end();
}

namespace detail {
namespace {
// Listeners whose calls are running on this thread (innermost last).
thread_local std::vector<const ListenerSlot*> runningHere;
}  // namespace

ListenerCall::ListenerCall(ListenerSlot& s) : slot_(s) {
    std::lock_guard g(s.m);
    entered_ = s.connected;
    if (entered_) {
        ++s.running;
        runningHere.push_back(&s);
    }
}

ListenerCall::~ListenerCall() {
    if (!entered_) return;
    runningHere.pop_back();
    std::lock_guard g(slot_.m);
    --slot_.running;
    slot_.idle.notify_all();
}

void retireListener(ListenerSlot& s) {
    const auto mine = std::count(runningHere.begin(), runningHere.end(), &s);
    std::unique_lock l(s.m);
    s.connected = false;
    s.idle.wait(l, [&] { return s.running == mine; });
}
}  // namespace detail

}  // namespace nativebind
