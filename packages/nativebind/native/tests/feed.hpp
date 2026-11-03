#pragma once
// Decoder for the change feed plus a "mirror" that applies it the way the
// Dart runtime does. The mirror is the reference consumer: tests compare it to
// the C++ state to prove the feed is complete and consistent.

#include <atomic>
#include <cstdint>
#include <map>
#include <string>
#include <vector>

#include "nativebind/codec.hpp"
#include "nativebind/detail/core.hpp"
#include "nativebind/nativebind.h"

namespace feed {

using nativebind::Tag;
using nativebind::detail::Rec;

/// A decoded value (generic, like Dart's Object?).
struct Value {
    Tag tag = Tag::Void;
    bool b = false;
    int64_t i = 0;  ///< Int, Enum, Time, Duration
    double d = 0;
    std::string s;
    std::vector<Value> items;  ///< List items or Struct fields

    bool operator==(const Value&) const = default;
};

Value readValue(nativebind::Reader& r);
std::string describe(const Value& v);

/// Encodes values back to back (one value for nativebind_write, the arguments
/// for nativebind_invoke).
template <class... A>
std::vector<uint8_t> encode(const A&... values) {
    std::vector<uint8_t> buf;
    nativebind::Writer w(buf);
    (w.value(values), ...);
    return buf;
}

/// Encodes a C++ value and decodes it into a generic Value.
template <class T>
Value valueOf(const T& v) {
    std::vector<uint8_t> buf;
    nativebind::Writer w(buf);
    w.value(v);
    nativebind::Reader r(buf.data(), buf.size());
    return readValue(r);
}

struct Record {
    Rec kind{};
    uint32_t instance = 0;
    uint16_t member = 0;  ///< prop, list or signal index
    uint16_t type = 0;
    uint64_t key = 0;
    uint32_t seq = 0;
    uint32_t version = 0;
    uint32_t index = 0, count = 0, from = 0, to = 0;
    uint32_t callId = 0;
    int32_t status = 0;
    std::string error;
    // meta
    double min = 0, max = 0, step = 0;
    uint8_t flags = 0;
    std::string label;
    std::vector<std::pair<std::string, Value>> attrs;
    std::vector<Value> values;  ///< prop value, list items, signal args, result
};

std::vector<Record> decode(const uint8_t* data, size_t len);

struct MetaState {
    double min = 0, max = 0, step = 0;
    uint8_t flags = 0;
    std::string label;
    std::vector<std::pair<std::string, Value>> attrs;
    /// The attribute named `key`, or a Void value.
    Value attr(const std::string& key) const {
        for (const auto& [k, v] : attrs)
            if (k == key) return v;
        return {};
    }
};

struct PropState {
    Value value;
    uint32_t seq = 0;
    MetaState meta;
};

struct ListState {
    uint32_t version = 0;
    std::vector<Value> items;
};

struct InstanceState {
    uint16_t type = 0;
    uint64_t key = 0;
    std::map<uint16_t, PropState> props;
    std::map<uint16_t, ListState> lists;
};

/// Applies records like the Dart runtime.
struct Mirror {
    std::map<uint32_t, InstanceState> instances;
    std::vector<Record> signals;
    std::vector<Record> results;
    int resyncs = 0;
    int gaps = 0;  ///< version gaps detected (must stay 0)

    void apply(const std::vector<Record>& records);
    const InstanceState* find(uint32_t handle) const;
};

/// Attaches as the feed consumer through the C callback and pumps it.
class Consumer {
public:
    Consumer();
    /// Drains once, applies to the mirror and returns the records.
    std::vector<Record> pump();
    /// nativebind_flush + pump.
    std::vector<Record> settle();
    int wakes() const { return wakes_.load(); }

    Mirror mirror;

private:
    static void onWake(void* self);
    std::atomic<int> wakes_{0};
};

/// Starts the runtime for one test and stops it afterwards.
struct Started {
    Started();
    ~Started();
    Started(const Started&) = delete;
    Started& operator=(const Started&) = delete;
};

/// Records of a given kind.
std::vector<Record> only(const std::vector<Record>& records, Rec kind);

}  // namespace feed
