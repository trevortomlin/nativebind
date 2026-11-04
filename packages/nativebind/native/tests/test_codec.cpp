#include <chrono>
#include <limits>
#include <optional>
#include <string>
#include <vector>

#include "feed.hpp"
#include "harness.hpp"
#include "modules/thermo.cpp"  // class definitions only (all inline), safe to include

using namespace nativebind;

namespace {

template <class T>
T roundTrip(const T& v) {
    auto buf = feed::encode(v);
    Reader r(buf.data(), buf.size());
    T out = r.value<T>();
    r.finish();
    return out;
}

}  // namespace

TEST(codec_primitives_round_trip) {
    CHECK_EQ(roundTrip(true), true);
    CHECK_EQ(roundTrip(false), false);
    CHECK_EQ(roundTrip(int32_t{-42}), -42);
    CHECK_EQ(roundTrip(std::numeric_limits<int64_t>::min()), std::numeric_limits<int64_t>::min());
    CHECK_EQ(roundTrip(uint8_t{255}), uint8_t{255});
    CHECK_EQ(roundTrip(21.5), 21.5);
    CHECK_EQ(roundTrip(std::numeric_limits<double>::infinity()), std::numeric_limits<double>::infinity());
    CHECK_EQ(roundTrip(std::string("Zone 1 — °C")), std::string("Zone 1 — °C"));
    CHECK_EQ(roundTrip(std::string()), std::string());
    CHECK(roundTrip(Stage::High) == Stage::High);
}

TEST(codec_containers_round_trip) {
    std::vector<double> v{1.5, -2, 3};
    CHECK(roundTrip(v) == v);
    std::vector<std::string> s{"a", "", "c"};
    CHECK(roundTrip(s) == s);
    std::vector<bool> b{true, false, true};
    CHECK(roundTrip(b) == b);
    CHECK(roundTrip(std::optional<int32_t>{}) == std::nullopt);
    CHECK(roundTrip(std::optional<int32_t>{7}) == std::optional<int32_t>{7});
    std::vector<std::optional<double>> vo{1.0, std::nullopt};
    CHECK(roundTrip(vo) == vo);
}

TEST(codec_time_and_duration) {
    using namespace std::chrono;
    const auto t = time_point_cast<microseconds>(system_clock::now());
    CHECK(roundTrip(t) == t);
    const auto coarse = time_point_cast<seconds>(system_clock::now());
    CHECK(roundTrip(coarse) == coarse);
    CHECK(roundTrip(minutes(90)) == minutes(90));
    CHECK(roundTrip(milliseconds(-1500)) == milliseconds(-1500));
    CHECK_EQ(feed::valueOf(seconds(2)).i, 2'000'000);
}

namespace {
std::vector<uint8_t> micros(Tag tag, int64_t us) {
    std::vector<uint8_t> buf;
    Writer w(buf);
    w.tag(tag);
    w.i64(us);
    return buf;
}
template <class T>
T decodeAs(const std::vector<uint8_t>& buf) {
    Reader r(buf.data(), buf.size());
    return r.value<T>();
}
}  // namespace

TEST(codec_time_and_duration_out_of_range_are_rejected_not_wrapped) {
    using namespace std::chrono;
    constexpr int64_t year9999 = 253402300799000000;  // DateTime(9999, 12, 31, 23, 59, 59) from Dart
    // system_clock counts nanoseconds on libstdc++: 2.5e20 ns does not fit.
    if constexpr (std::ratio_less_v<system_clock::period, std::micro>) {
        CHECK_THROWS(decodeAs<system_clock::time_point>(micros(Tag::Time, year9999)), DecodeError);
        CHECK_THROWS(decodeAs<system_clock::time_point>(micros(Tag::Time, -year9999)), DecodeError);
    }
    // ... but it does in a coarser time point.
    const auto coarse = decodeAs<time_point<system_clock, seconds>>(micros(Tag::Time, year9999));
    CHECK_EQ(coarse.time_since_epoch().count(), int64_t{253402300799});

    CHECK_THROWS(decodeAs<nanoseconds>(micros(Tag::Duration, std::numeric_limits<int64_t>::max())), DecodeError);
    CHECK_THROWS(decodeAs<nanoseconds>(micros(Tag::Duration, std::numeric_limits<int64_t>::min())), DecodeError);
    CHECK_THROWS((decodeAs<duration<int32_t>>(micros(Tag::Duration, int64_t{1} << 60))), DecodeError);
    CHECK_EQ(decodeAs<nanoseconds>(micros(Tag::Duration, -1500)).count(), int64_t{-1'500'000});
    CHECK_EQ(decodeAs<seconds>(micros(Tag::Duration, -1'500'000)).count(), int64_t{-1});  // truncates like duration_cast
    CHECK_EQ(decodeAs<duration<double>>(micros(Tag::Duration, 1'500'000)).count(), 1.5);

    // Encoding coarse values beyond the microsecond range saturates (Dart
    // clamps such "never" sentinels) instead of overflowing.
    CHECK_EQ(feed::valueOf(hours::max()).i, std::numeric_limits<int64_t>::max());
    CHECK_EQ(feed::valueOf(hours::min()).i, std::numeric_limits<int64_t>::min());
    CHECK_EQ(feed::valueOf(time_point<system_clock, seconds>::max()).i, std::numeric_limits<int64_t>::max());
}

TEST(codec_struct_uses_generated_codec) {
    Reading r{"floor", 23.25, {1, 2, 3}};
    CHECK(roundTrip(r) == r);
    std::vector<Reading> rs{r, Reading{"air", -1, {}}};
    CHECK(roundTrip(rs) == rs);

    const feed::Value v = feed::valueOf(r);
    CHECK(v.tag == Tag::Struct);
    CHECK_EQ(v.items.size(), size_t{3});
    CHECK_EQ(v.items[0].s, std::string("floor"));
    CHECK_EQ(v.items[1].d, 23.25);
    CHECK_EQ(v.items[2].items.size(), size_t{3});
}

TEST(codec_unregistered_struct_is_a_clear_error) {
    struct NotGenerated {
        int x = 0;
    };
    std::vector<uint8_t> buf;
    Writer w(buf);
    CHECK_THROWS(w.value(NotGenerated{}), std::logic_error);
}

TEST(codec_rejects_bad_input) {
    {
        auto buf = feed::encode(std::string("x"));
        Reader r(buf.data(), buf.size());
        CHECK_THROWS(r.value<double>(), DecodeError);  // wrong tag
    }
    {
        auto buf = feed::encode(int64_t{300});
        Reader r(buf.data(), buf.size());
        CHECK_THROWS(r.value<uint8_t>(), DecodeError);  // out of range
    }
    {
        auto buf = feed::encode(int64_t{-1});
        Reader r(buf.data(), buf.size());
        CHECK_THROWS(r.value<uint32_t>(), DecodeError);
    }
    {
        auto buf = feed::encode(std::string("hello"));
        buf.resize(buf.size() - 2);  // truncated
        Reader r(buf.data(), buf.size());
        CHECK_THROWS(r.value<std::string>(), DecodeError);
    }
    {
        std::vector<uint8_t> buf{static_cast<uint8_t>(Tag::List), 0xff, 0xff, 0xff, 0x7f};  // huge count
        Reader r(buf.data(), buf.size());
        CHECK_THROWS(r.value<std::vector<int32_t>>(), DecodeError);
    }
    {
        auto buf = feed::encode(1.0, 2.0);
        Reader r(buf.data(), buf.size());
        (void)r.value<double>();
        CHECK_THROWS(r.finish(), DecodeError);  // extra data
    }
    {
        Reader r(nullptr, 0);
        CHECK_THROWS(r.value<bool>(), DecodeError);
    }
}

TEST(codec_int_is_accepted_for_double) {
    auto buf = feed::encode(int64_t{22});  // Dart may send an int literal
    Reader r(buf.data(), buf.size());
    CHECK_EQ(r.value<double>(), 22.0);
}

TEST(codec_struct_field_count_mismatch) {
    std::vector<uint8_t> buf;
    Writer w(buf);
    w.beginStruct(2);
    w.value(std::string("x"));
    w.value(1.0);
    Reader r(buf.data(), buf.size());
    CHECK_THROWS(r.value<Reading>(), DecodeError);
}
