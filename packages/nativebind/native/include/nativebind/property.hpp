#pragma once
// Bound properties: NATIVEBIND_PROP (UI may write) and NATIVEBIND_READ (UI may not).

#include <cmath>
#include <concepts>
#include <exception>
#include <functional>
#include <mutex>
#include <optional>
#include <type_traits>
#include <utility>
#include <vector>

#include "nativebind/module.hpp"
#include "nativebind/types.hpp"

namespace nativebind {

namespace detail {

template <class T>
constexpr bool comparable() {
    if constexpr (is_vector<T>::value || is_optional<T>::value) return comparable<typename T::value_type>();
    else return std::equality_comparable<T>;
}

/// Equality used to suppress no-op updates. Types without operator== always
/// count as changed; give structs `bool operator==(const T&) const = default;`.
template <class T>
bool equal(const T& a, const T& b) {
    if constexpr (comparable<T>()) return a == b;
    else return false;
}

}  // namespace detail

/// Type-independent part of a property. All methods are thread-safe.
class PropBase {
public:
    PropBase(const PropBase&) = delete;
    PropBase& operator=(const PropBase&) = delete;

    const char* name() const noexcept { return name_; }
    /// Declaration index among the module's properties (wire id).
    uint16_t index() const noexcept { return index_; }
    Module& owner() const noexcept { return *owner_; }
    /// False for NATIVEBIND_READ.
    bool writable() const noexcept { return writable_; }
    virtual Tag wireTag() const noexcept = 0;

    Meta meta() const;
    void setMeta(const Meta& m);
    /// Changes the range the UI may write (e.g. a limit that depends on equipment type).
    void setRange(double min, double max);
    void setStep(double step);

    /// A disabled property is shown greyed out and rejects UI writes.
    bool enabled() const;
    void setEnabled(bool enabled);

protected:
    PropBase(Module* owner, const char* name, const Meta& meta, bool writable);
    virtual ~PropBase() = default;

    /// Call after the value changed (outside mutex_).
    void changed() { detail::propChanged(*this); }

    mutable std::mutex mutex_;
    Meta meta_;
    bool enabled_ = true;
    uint32_t ackSeq_ = 0;  ///< last UI write sequence number processed

private:
    friend class detail::Runtime;

    /// Writes ack sequence and value (locks mutex_).
    void encodeState(Writer& w) const;
    /// Writes the metadata record payload (locks mutex_).
    void encodeMeta(Writer& w) const;
    virtual void encodeValueLocked(Writer& w) const = 0;
    /// Decodes a UI write on the caller's thread and queues it for the nativebind
    /// thread. Throws DecodeError on a type mismatch.
    virtual void uiWrite(Reader& r, uint32_t seq) = 0;

    Module* const owner_;
    const char* const name_;
    const uint16_t index_;
    const bool writable_;
    std::atomic<bool> dirty_{false};
    std::atomic<bool> metaDirty_{false};
};

/// A bound value. Reads and writes are thread-safe; assigning a different
/// value pushes it to Flutter (coalesced: Flutter sees the latest value).
///
///     position = decoder.seconds();       // set
///     double v = volume;                  // get
template <class T>
class Prop final : public PropBase {
public:
    using value_type = T;

    Prop(Module* owner, const char* name, T initial, const Meta& meta = {}, bool writable = true)
        : PropBase(owner, name, meta, writable), value_(std::move(initial)) {
        (void)tagOf<T>();  // rejects unsupported types at compile time
    }

    T get() const {
        std::lock_guard g(mutex_);
        return value_;
    }
    operator T() const { return get(); }
    T operator()() const { return get(); }

    /// Sets the value; returns true if it changed.
    bool set(const T& v) {
        {
            std::lock_guard g(mutex_);
            if (detail::equal(value_, v)) return false;
            value_ = v;
        }
        changed();
        return true;
    }
    Prop& operator=(const T& v) {
        set(v);
        return *this;
    }
    /// Copies another property's current value: `a = b` means `a = b.get()`
    /// (the property itself, its name and metadata, are never copied).
    Prop& operator=(const Prop& other) {
        if (this != &other) set(other.get());
        return *this;
    }
    template <class U>
        requires(!std::is_same_v<U, T> && std::is_convertible_v<U, T>)
    Prop& operator=(const Prop<U>& other) {
        set(static_cast<T>(other.get()));
        return *this;
    }

    /// Filters UI writes before they are stored. Runs on the nativebind thread.
    /// `fn(const T&)` returns
    ///   bool              accept or reject the value,
    ///   T                 the value to store instead (e.g. rounded), or
    ///   std::optional<T>  a replacement, or nullopt to reject.
    /// A rejected write reverts the UI to the current value.
    /// Install handlers in the constructor or onStart().
    template <class F>
    Prop& validate(F fn) {
        using R = std::invoke_result_t<F&, const T&>;
        if constexpr (std::is_same_v<R, bool>) {
            validator_ = [fn = std::move(fn)](const T& v) mutable -> std::optional<T> {
                if (fn(v)) return v;
                return std::nullopt;
            };
        } else if constexpr (std::is_convertible_v<R, std::optional<T>>) {
            validator_ = [fn = std::move(fn)](const T& v) mutable -> std::optional<T> { return fn(v); };
        } else {
            static_assert(detail::always_false<F>, "validate(fn): fn must return bool, T or std::optional<T>");
        }
        return *this;
    }

    /// Called on the nativebind thread after a UI write was stored (not for
    /// changes made by C++). Install handlers in the constructor or onStart().
    Prop& onWrite(std::function<void(const T&)> fn) {
        onWrite_.push_back(std::move(fn));
        return *this;
    }

    Tag wireTag() const noexcept override { return tagOf<T>(); }

private:
    void encodeValueLocked(Writer& w) const override { w.value(value_); }

    void uiWrite(Reader& r, uint32_t seq) override {
        T v = r.template value<T>();
        r.finish();
        detail::postFor(owner().handle(), [this, v = std::move(v), seq]() mutable { applyUiWrite(std::move(v), seq); });
    }

    // Runs on the nativebind thread. The UI thread checked `enabled` when the
    // write arrived, but C++ may have changed the metadata since: the range
    // and the enabled flag are applied as they are now.
    void applyUiWrite(T v, uint32_t seq) {
        bool enabled;
        {
            std::lock_guard g(mutex_);
            enabled = enabled_;
            if constexpr (std::is_arithmetic_v<T> && !std::is_same_v<T, bool>) {
                const double d = static_cast<double>(v);
                const double lo = meta_.min, hi = meta_.max;
                if constexpr (std::is_integral_v<T>) {
                    if (d < lo) v = static_cast<T>(std::ceil(lo));
                    if (d > hi) v = static_cast<T>(std::floor(hi));
                } else {
                    if (d < lo) v = static_cast<T>(lo);
                    if (d > hi) v = static_cast<T>(hi);
                }
            }
        }
        std::optional<T> accepted;
        if (enabled) {
            try {
                accepted = validator_ ? validator_(v) : std::optional<T>(std::move(v));
            } catch (const std::exception& e) {
                detail::logf("validator of %s threw: %s (write rejected)", name(), e.what());
            } catch (...) {
                detail::logf("validator of %s threw a non-std exception (write rejected)", name());
            }
        }
        {
            std::lock_guard g(mutex_);
            if (accepted) value_ = *accepted;
            ackSeq_ = seq;
        }
        changed();  // always echo, so the UI drops its optimistic value
        if (accepted)
            for (auto& h : onWrite_) h(*accepted);
    }

    T value_;
    std::function<std::optional<T>(const T&)> validator_;
    std::vector<std::function<void(const T&)>> onWrite_;
};

}  // namespace nativebind
