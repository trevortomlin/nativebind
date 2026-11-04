#pragma once
// Bound lists: NATIVEBIND_LIST. Flutter mirrors the list through incremental
// operations (insert, remove, update, move, reset), so a ListView only
// rebuilds the rows that changed.

#include <algorithm>
#include <concepts>
#include <cstddef>
#include <functional>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include "nativebind/module.hpp"
#include "nativebind/property.hpp"

namespace nativebind {

namespace detail {

template <class K>
concept Hashable = requires(const K& k) {
    { std::hash<K>{}(k) } -> std::convertible_to<std::size_t>;
};

/// Counts which of n slots are still set (all are at first): before(o) is the
/// number of set slots below o. O(log n) each.
class Fenwick {
public:
    explicit Fenwick(std::size_t n) : tree_(n + 1, 0) {
        for (std::size_t i = 1; i <= n; ++i) {
            tree_[i] += 1;
            const std::size_t parent = i + (i & (~i + 1));
            if (parent <= n) tree_[parent] += tree_[i];
        }
    }
    std::size_t before(std::size_t o) const {
        std::size_t sum = 0;
        for (std::size_t i = o; i > 0; i -= i & (~i + 1)) sum += tree_[i];
        return sum;
    }
    void remove(std::size_t o) {
        for (std::size_t i = o + 1; i < tree_.size(); i += i & (~i + 1)) --tree_[i];
    }

private:
    std::vector<std::size_t> tree_;
};

}  // namespace detail

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
    ///
    /// With a key that has std::hash (strings, integers) this takes O(n log n)
    /// time; with a key that only has ==, O(n x m).
    template <class KeyFn>
    void sync(const std::vector<T>& next, KeyFn key) {
        std::lock_guard g(mutex_);
        using K = std::decay_t<decltype(key(next.front()))>;
        std::vector<K> nextKeys;
        nextKeys.reserve(next.size());
        for (const auto& v : next) nextKeys.push_back(key(v));
        if constexpr (detail::Hashable<K>) syncHashedLocked(next, nextKeys, key);
        else syncLinearLocked(next, nextKeys, key);
    }

private:
    // Both versions emit the same operations: remove what `next` lacks (from
    // the back), then for each position take the first remaining item with
    // that key (moving it up) or insert, then drop the rest.

    template <class K, class KeyFn>
    void syncLinearLocked(const std::vector<T>& next, const std::vector<K>& nextKeys, KeyFn& key) {
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

    // Emits the same operations without applying each one to items_ (every
    // move would shift the rows in between): positions come from a Fenwick
    // tree, and items_ becomes `next` at the end.
    template <class K, class KeyFn>
    void syncHashedLocked(const std::vector<T>& next, const std::vector<K>& nextKeys, KeyFn& key) {
        try {
            {
                const std::unordered_set<K> wanted(nextKeys.begin(), nextKeys.end());
                std::vector<bool> keep(items_.size());
                for (size_t i = items_.size(); i-- > 0;) {
                    keep[i] = wanted.contains(key(items_[i]));
                    if (!keep[i]) emitRemoveLocked(i, 1);
                }
                size_t kept = 0;
                for (size_t i = 0; i < items_.size(); ++i) {
                    if (!keep[i]) continue;
                    if (kept != i) items_[kept] = std::move(items_[i]);  // never a self-move
                    ++kept;
                }
                items_.resize(kept);
            }
            // The items left are numbered 0..r-1 in their order now. At step i
            // the list is [i placed items][the remaining ones, in that order],
            // so remaining item o is at i + (remaining items before o).
            const size_t r = items_.size();
            std::unordered_map<K, std::vector<size_t>> byKey;  // remaining items per key, in order
            for (size_t o = 0; o < r; ++o) byKey[key(items_[o])].push_back(o);
            std::unordered_map<K, size_t> taken;  // how many of byKey[k] are placed
            detail::Fenwick remaining(r);
            size_t left = r;
            for (size_t i = 0; i < next.size(); ++i) {
                auto it = byKey.find(nextKeys[i]);
                size_t& used = taken[nextKeys[i]];
                if (it == byKey.end() || used == it->second.size()) {
                    emitInsertLocked(i, next[i]);
                    continue;
                }
                const size_t o = it->second[used++];
                const size_t j = i + remaining.before(o);
                remaining.remove(o);
                --left;
                if (j != i) emitMoveLocked(j, i);
                if (!detail::equal(items_[o], next[i])) emitUpdateLocked(i, next[i]);
            }
            if (left > 0) emitRemoveLocked(next.size(), left);
        } catch (...) {
            // Flutter may have some of the operations: send the whole list.
            items_ = next;
            try {
                emitResetLocked();
            } catch (...) {
            }
            throw;
        }
        items_ = next;
    }

    static void check(size_t i, size_t n) {
        if (i >= n) throw std::out_of_range("nativebind::List index out of range");
    }
    void insertLocked(size_t i, T v) {
        items_.insert(items_.begin() + static_cast<std::ptrdiff_t>(i), std::move(v));
        emitInsertLocked(i, items_[i]);
    }
    void eraseLocked(size_t i, size_t count) {
        auto first = items_.begin() + static_cast<std::ptrdiff_t>(i);
        items_.erase(first, first + static_cast<std::ptrdiff_t>(count));
        emitRemoveLocked(i, count);
    }
    void emitInsertLocked(size_t i, const T& v) {
        emitLocked(detail::Rec::ListInsert, [&](Writer& w) {
            w.u32(static_cast<uint32_t>(i));
            w.value(v);
        });
    }
    void emitRemoveLocked(size_t i, size_t count) {
        emitLocked(detail::Rec::ListRemove, [&](Writer& w) {
            w.u32(static_cast<uint32_t>(i));
            w.u32(static_cast<uint32_t>(count));
        });
    }
    void emitUpdateLocked(size_t i, const T& v) {
        emitLocked(detail::Rec::ListUpdate, [&](Writer& w) {
            w.u32(static_cast<uint32_t>(i));
            w.value(v);
        });
    }
    void emitMoveLocked(size_t from, size_t to) {
        emitLocked(detail::Rec::ListMove, [&](Writer& w) {
            w.u32(static_cast<uint32_t>(from));
            w.u32(static_cast<uint32_t>(to));
        });
    }
    void setLocked(size_t i, T v) {
        if (detail::equal(items_[i], v)) return;
        items_[i] = std::move(v);
        emitUpdateLocked(i, items_[i]);
    }
    void moveLocked(size_t from, size_t to) {
        if (from == to) return;
        auto b = items_.begin();
        if (from < to) std::rotate(b + from, b + from + 1, b + to + 1);
        else std::rotate(b + to, b + from, b + from + 1);
        emitMoveLocked(from, to);
    }
    void encodeItemsLocked(Writer& w) const override {
        w.u32(static_cast<uint32_t>(items_.size()));
        for (const auto& v : items_) w.value(v);
    }

    std::vector<T> items_;
};

}  // namespace nativebind
