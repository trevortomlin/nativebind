#pragma once
// Bound lists: NATIVEBIND_LIST. Flutter mirrors the list through incremental
// operations (insert, remove, update, move, reset), so a ListView only
// rebuilds the rows that changed.

#include <algorithm>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <utility>
#include <vector>

#include "nativebind/module.hpp"
#include "nativebind/property.hpp"

namespace nativebind {

/// Type-independent part of a list.
class ListBase {
public:
    ListBase(const ListBase&) = delete;
    ListBase& operator=(const ListBase&) = delete;

    const char* name() const noexcept { return name_; }
    uint16_t index() const noexcept { return index_; }
    Module& owner() const noexcept { return *owner_; }

protected:
    ListBase(Module* owner, const char* name);
    virtual ~ListBase() = default;

    /// Bumps the version and, if the module is live, queues an operation
    /// record. Call with mutex_ held.
    template <class F>
    void emitLocked(detail::Rec kind, const F& payload) {
        ++version_;
        if (!live_) return;
        const uint32_t h = owner_->handle();
        detail::event(kind, [&](Writer& w) {
            w.u32(h);
            w.u16(index_);
            w.u32(version_);
            payload(w);
        });
    }
    void emitResetLocked() {
        emitLocked(detail::Rec::ListReset, [&](Writer& w) { encodeItemsLocked(w); });
    }

    mutable std::mutex mutex_;

private:
    friend class detail::Runtime;
    /// u32 count followed by the items.
    virtual void encodeItemsLocked(Writer& w) const = 0;
    void goLive();
    void goDead();
    void encodeReset(Writer& w) const;

    Module* const owner_;
    const char* const name_;
    const uint16_t index_;
    uint32_t version_ = 0;
    bool live_ = false;
};

/// A bound, thread-safe list of T (any supported value type, typically a
/// struct). Indexes are checked; out-of-range access throws std::out_of_range.
template <class T>
class List final : public ListBase {
public:
    using value_type = T;

    List(Module* owner, const char* name) : ListBase(owner, name) { (void)tagOf<T>(); }

    size_t size() const {
        std::lock_guard g(mutex_);
        return items_.size();
    }
    bool empty() const { return size() == 0; }
    T at(size_t i) const {
        std::lock_guard g(mutex_);
        check(i, items_.size());
        return items_[i];
    }
    /// Copy of all items.
    std::vector<T> items() const {
        std::lock_guard g(mutex_);
        return items_;
    }
    template <class Pred>
    std::optional<size_t> findIndex(Pred pred) const {
        std::lock_guard g(mutex_);
        for (size_t i = 0; i < items_.size(); ++i)
            if (pred(items_[i])) return i;
        return std::nullopt;
    }

    void push_back(T v) {
        std::lock_guard g(mutex_);
        insertLocked(items_.size(), std::move(v));
    }
    void insert(size_t i, T v) {
        std::lock_guard g(mutex_);
        check(i, items_.size() + 1);
        insertLocked(i, std::move(v));
    }
    void erase(size_t i, size_t count = 1) {
        std::lock_guard g(mutex_);
        const size_t n = items_.size();
        // Compared against what remains after i, so a huge count cannot wrap.
        if (i > n || count > n - i) throw std::out_of_range("nativebind::List::erase range out of range");
        if (count == 0) return;
        eraseLocked(i, count);
    }
    /// Removes every item matching pred; returns how many were removed.
    template <class Pred>
    size_t eraseIf(Pred pred) {
        std::lock_guard g(mutex_);
        size_t removed = 0;
        for (size_t i = items_.size(); i-- > 0;)
            if (pred(items_[i])) {
                eraseLocked(i, 1);
                ++removed;
            }
        return removed;
    }
    /// Replaces item i (no-op if equal).
    void set(size_t i, T v) {
        std::lock_guard g(mutex_);
        check(i, items_.size());
        setLocked(i, std::move(v));
    }
    /// Edits item i in place: `list.update(i, [](Track& t) { t.liked = true; })`.
    /// fn runs with the list locked; it must not touch this list.
    template <class F>
    void update(size_t i, F&& fn) {
        std::lock_guard g(mutex_);
        check(i, items_.size());
        T copy = items_[i];
        fn(copy);
        setLocked(i, std::move(copy));
    }
    /// Moves item `from` so that it ends up at index `to`.
    void move(size_t from, size_t to) {
        std::lock_guard g(mutex_);
        check(from, items_.size());
        check(to, items_.size());
        moveLocked(from, to);
    }
    void clear() {
        std::lock_guard g(mutex_);
        if (items_.empty()) return;
        items_.clear();
        emitResetLocked();
    }
    /// Replaces all items (one reset; prefer sync() to keep row identity).
    void assign(std::vector<T> items) {
        std::lock_guard g(mutex_);
        items_ = std::move(items);
        emitResetLocked();
    }

    /// Makes the list equal to `next` with the fewest operations, matching
    /// items by key so rows keep their identity (and animations) in Flutter:
    ///
    ///     tracks.sync(fetchTracks(), [](const Track& t) { return t.id; });
    template <class KeyFn>
    void sync(const std::vector<T>& next, KeyFn key) {
        std::lock_guard g(mutex_);
        using K = std::decay_t<decltype(key(next.front()))>;
        std::vector<K> nextKeys;
        nextKeys.reserve(next.size());
        for (const auto& v : next) nextKeys.push_back(key(v));
        auto inNext = [&](const K& k) { return std::find(nextKeys.begin(), nextKeys.end(), k) != nextKeys.end(); };

        for (size_t i = items_.size(); i-- > 0;)
            if (!inNext(key(items_[i]))) eraseLocked(i, 1);

        for (size_t i = 0; i < next.size(); ++i) {
            if (i < items_.size() && key(items_[i]) == nextKeys[i]) {
                setLocked(i, next[i]);
                continue;
            }
            size_t j = i + 1;
            while (j < items_.size() && !(key(items_[j]) == nextKeys[i])) ++j;
            if (j < items_.size()) {
                moveLocked(j, i);
                setLocked(i, next[i]);
            } else {
                insertLocked(i, next[i]);
            }
        }
        if (items_.size() > next.size()) eraseLocked(next.size(), items_.size() - next.size());
    }

private:
    static void check(size_t i, size_t n) {
        if (i >= n) throw std::out_of_range("nativebind::List index out of range");
    }
    void insertLocked(size_t i, T v) {
        items_.insert(items_.begin() + static_cast<std::ptrdiff_t>(i), std::move(v));
        emitLocked(detail::Rec::ListInsert, [&](Writer& w) {
            w.u32(static_cast<uint32_t>(i));
            w.value(items_[i]);
        });
    }
    void eraseLocked(size_t i, size_t count) {
        auto first = items_.begin() + static_cast<std::ptrdiff_t>(i);
        items_.erase(first, first + static_cast<std::ptrdiff_t>(count));
        emitLocked(detail::Rec::ListRemove, [&](Writer& w) {
            w.u32(static_cast<uint32_t>(i));
            w.u32(static_cast<uint32_t>(count));
        });
    }
    void setLocked(size_t i, T v) {
        if (detail::equal(items_[i], v)) return;
        items_[i] = std::move(v);
        emitLocked(detail::Rec::ListUpdate, [&](Writer& w) {
            w.u32(static_cast<uint32_t>(i));
            w.value(items_[i]);
        });
    }
    void moveLocked(size_t from, size_t to) {
        if (from == to) return;
        auto b = items_.begin();
        if (from < to) std::rotate(b + from, b + from + 1, b + to + 1);
        else std::rotate(b + to, b + from, b + from + 1);
        emitLocked(detail::Rec::ListMove, [&](Writer& w) {
            w.u32(static_cast<uint32_t>(from));
            w.u32(static_cast<uint32_t>(to));
        });
    }
    void encodeItemsLocked(Writer& w) const override {
        w.u32(static_cast<uint32_t>(items_.size()));
        for (const auto& v : items_) w.value(v);
    }

    std::vector<T> items_;
};

}  // namespace nativebind
