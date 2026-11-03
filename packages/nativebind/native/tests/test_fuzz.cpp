// Property-based and fuzz tests: untrusted bytes from the UI never crash the
// runtime, and random list operations always mirror exactly.

#include <algorithm>
#include <cstdint>
#include <random>
#include <string>
#include <vector>

#include "feed.hpp"
#include "harness.hpp"
#include "modules/thermo.cpp"  // class definitions only (all inline), safe to include

using namespace nativebind;

namespace {

std::vector<uint8_t> randomBytes(std::mt19937& rng, size_t maxLen) {
    std::vector<uint8_t> out(rng() % (maxLen + 1));
    for (auto& b : out) b = static_cast<uint8_t>(rng());
    return out;
}

/// Random but well-formed encoded values (for decode-into-the-wrong-type tests).
std::vector<uint8_t> randomValue(std::mt19937& rng, int depth = 0) {
    std::vector<uint8_t> buf;
    Writer w(buf);
    switch (rng() % (depth > 2 ? 6 : 9)) {
        case 0: w.value(rng() % 2 == 0); break;
        case 1: w.value(static_cast<int64_t>(rng()) - (1 << 30)); break;
        case 2: w.value(static_cast<double>(rng()) / 7.0); break;
        case 3: w.value(std::string(rng() % 20, 'x')); break;
        case 4: w.value(Stage::High); break;
        case 5: w.value(std::optional<int32_t>{}); break;
        case 6: w.value(std::vector<int32_t>(rng() % 5, 7)); break;
        case 7: w.value(Reading{"s", 1.0, {1}}); break;
        default: w.value(std::chrono::seconds(rng() % 100)); break;
    }
    return buf;
}

template <class T>
void decodeOrThrow(const std::vector<uint8_t>& bytes) {
    try {
        Reader r(bytes.data(), bytes.size());
        (void)r.value<T>();
    } catch (const DecodeError&) {
    }
}

}  // namespace

TEST(fuzz_reader_never_crashes_on_garbage) {
    std::mt19937 rng(1234);
    for (int i = 0; i < 20000; ++i) {
        const auto bytes = randomBytes(rng, 64);
        decodeOrThrow<bool>(bytes);
        decodeOrThrow<int32_t>(bytes);
        decodeOrThrow<uint8_t>(bytes);
        decodeOrThrow<double>(bytes);
        decodeOrThrow<std::string>(bytes);
        decodeOrThrow<Stage>(bytes);
        decodeOrThrow<std::vector<std::string>>(bytes);
        decodeOrThrow<std::optional<double>>(bytes);
        decodeOrThrow<Reading>(bytes);
        decodeOrThrow<std::vector<Reading>>(bytes);
        decodeOrThrow<std::chrono::system_clock::time_point>(bytes);
    }
}

TEST(fuzz_well_formed_values_of_the_wrong_type_are_rejected_cleanly) {
    std::mt19937 rng(99);
    for (int i = 0; i < 5000; ++i) {
        const auto bytes = randomValue(rng);
        decodeOrThrow<Reading>(bytes);
        decodeOrThrow<std::vector<int32_t>>(bytes);
        decodeOrThrow<std::string>(bytes);
        decodeOrThrow<int8_t>(bytes);
    }
}

TEST(fuzz_truncations_of_valid_messages_are_rejected) {
    std::vector<uint8_t> full;
    Writer w(full);
    w.value(std::vector<Reading>{{"floor", 21.5, {1, 2, 3}}, {"air", -3, {}}});
    for (size_t n = 0; n < full.size(); ++n) {
        std::vector<uint8_t> cut(full.begin(), full.begin() + static_cast<std::ptrdiff_t>(n));
        Reader r(cut.data(), cut.size());
        CHECK_THROWS(r.value<std::vector<Reading>>(), DecodeError);
    }
    Reader ok(full.data(), full.size());
    CHECK_EQ(ok.value<std::vector<Reading>>().size(), size_t{2});
}

TEST(fuzz_abi_writes_and_invokes_with_random_payloads) {
    feed::Started s;
    feed::Consumer c;
    c.pump();
    auto& th = singleton<Thermo>();
    std::mt19937 rng(7);
    for (int i = 0; i < 3000; ++i) {
        const auto bytes = rng() % 2 ? randomBytes(rng, 40) : randomValue(rng);
        const auto prop = static_cast<uint16_t>(rng() % 8);  // includes invalid indexes
        const int32_t ws = nativebind_write(th.handle(), prop, bytes.data(), static_cast<uint32_t>(bytes.size()),
                                        static_cast<uint32_t>(i));
        CHECK(ws == NATIVEBIND_OK || ws == NATIVEBIND_E_TYPE || ws == NATIVEBIND_E_READ_ONLY || ws == NATIVEBIND_E_NO_MEMBER ||
              ws == NATIVEBIND_E_ACCESS);
        const auto method = static_cast<uint16_t>(rng() % 14);
        if (method == 3 || method == 5 || method == 6 || method == 13) continue;  // fail(), spawn/destroy: covered elsewhere
        const int32_t is = nativebind_invoke(th.handle(), method, bytes.data(), static_cast<uint32_t>(bytes.size()),
                                         static_cast<uint32_t>(i));
        CHECK(is == NATIVEBIND_OK || is == NATIVEBIND_E_NO_MEMBER);
        if (i % 100 == 0) c.settle();
    }
    c.settle();
    CHECK_EQ(c.mirror.gaps, 0);
    // Every accepted invoke produced exactly one result.
    for (const auto& r : c.mirror.results)
        CHECK(r.status == NATIVEBIND_OK || r.status == NATIVEBIND_E_TYPE || r.status == NATIVEBIND_E_ACCESS ||
              r.status == NATIVEBIND_E_EXCEPTION);
}

TEST(property_random_list_operations_mirror_exactly) {
    feed::Started s;
    feed::Consumer c;
    c.pump();
    auto& l = singleton<Thermo>().readings;
    std::mt19937 rng(42);
    std::vector<std::string> model;
    auto R = [](const std::string& k, double v = 0) { return Reading{k, v, {}}; };
    int nextKey = 0;
    for (int step = 0; step < 4000; ++step) {
        const auto n = model.size();
        switch (rng() % 9) {
            case 0:
            case 1: {
                const auto at = n == 0 ? 0 : rng() % (n + 1);
                const auto k = "k" + std::to_string(nextKey++);
                l.insert(at, R(k));
                model.insert(model.begin() + static_cast<std::ptrdiff_t>(at), k);
                break;
            }
            case 2:
                if (n > 0) {
                    const auto at = rng() % n;
                    const auto count = 1 + rng() % std::min<size_t>(3, n - at);
                    l.erase(at, count);
                    model.erase(model.begin() + static_cast<std::ptrdiff_t>(at),
                                model.begin() + static_cast<std::ptrdiff_t>(at + count));
                }
                break;
            case 3:
                if (n > 0) {
                    const auto at = rng() % n;
                    l.set(at, R(model[at], static_cast<double>(step)));  // same key, new value
                }
                break;
            case 4:
                if (n > 1) {
                    const auto from = rng() % n, to = rng() % n;
                    l.move(from, to);
                    const auto v = model[from];
                    model.erase(model.begin() + static_cast<std::ptrdiff_t>(from));
                    model.insert(model.begin() + static_cast<std::ptrdiff_t>(to), v);
                }
                break;
            case 5: {
                // sync to a random permutation/subset plus new items
                std::vector<std::string> next = model;
                std::shuffle(next.begin(), next.end(), rng);
                if (!next.empty() && rng() % 2) next.resize(rng() % next.size());
                for (int k = 0; k < static_cast<int>(rng() % 3); ++k) next.push_back("k" + std::to_string(nextKey++));
                std::vector<Reading> items;
                for (const auto& k : next) items.push_back(R(k));
                l.sync(items, [](const Reading& r) { return r.sensor; });
                model = next;
                break;
            }
            case 6:
                if (rng() % 10 == 0) {
                    l.clear();
                    model.clear();
                }
                break;
            default:
                l.push_back(R("k" + std::to_string(nextKey)));
                model.push_back("k" + std::to_string(nextKey++));
        }
        if (step % 7 == 0) c.pump();  // drain at random-ish points, sometimes many ops at once
        if (step % 500 == 0) nativebind_request_resync();
    }
    c.pump();
    const auto* inst = c.mirror.find(singleton<Thermo>().handle());
    CHECK(inst != nullptr);
    const auto& mirrored = inst->lists.at(0).items;
    CHECK_EQ(mirrored.size(), model.size());
    for (size_t i = 0; i < model.size(); ++i) CHECK_EQ(mirrored[i].items.at(0).s, model[i]);
    const auto actual = l.items();
    for (size_t i = 0; i < model.size(); ++i) {
        CHECK_EQ(actual[i].sensor, model[i]);
        CHECK(mirrored[i] == feed::valueOf(actual[i]));  // values too, not only keys
    }
    CHECK_EQ(c.mirror.gaps, 0);
}

TEST(property_sync_produces_minimal_operations_for_pure_moves) {
    feed::Started s;
    feed::Consumer c;
    auto& l = singleton<Thermo>().readings;
    std::vector<Reading> items;
    for (int i = 0; i < 50; ++i) items.push_back({"k" + std::to_string(i), static_cast<double>(i), {}});
    l.assign(items);
    c.pump();
    // Rotate by one: a single move, no inserts/removes/updates.
    std::rotate(items.begin(), items.begin() + 1, items.end());
    l.sync(items, [](const Reading& r) { return r.sensor; });
    const auto recs = c.pump();
    CHECK(feed::only(recs, feed::Rec::ListInsert).empty());
    CHECK(feed::only(recs, feed::Rec::ListRemove).empty());
    CHECK(feed::only(recs, feed::Rec::ListUpdate).empty());
    CHECK(feed::only(recs, feed::Rec::ListMove).size() <= 50);
    CHECK_EQ(c.mirror.gaps, 0);
}
