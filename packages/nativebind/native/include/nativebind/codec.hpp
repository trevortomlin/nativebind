#pragma once
// Binary encoding of values between C++ and Dart. The format is documented in
// doc/wire-format.md. Values are self-describing (tagged) and little-endian.
//
// Supported types: bool, integers, float/double, std::string, enums, structs
// (fields encoded by generated code), std::vector<T>, std::optional<T>,
// std::chrono::system_clock::time_point and std::chrono::duration.

#include <bit>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <limits>
#include <optional>
#include <ratio>
#include <stdexcept>
#include <string>
#include <string_view>
#include <type_traits>
#include <typeindex>
#include <typeinfo>
#include <utility>
#include <vector>

namespace nativebind {

static_assert(std::endian::native == std::endian::little, "nativebind's wire format assumes a little-endian host");

/// Type tag that precedes every encoded value.
enum class Tag : uint8_t {
    Void = 0,
    Bool = 1,      ///< u8 0/1
    Int = 2,       ///< i64
    Double = 3,    ///< f64
    String = 4,    ///< u32 byte length + UTF-8
    Enum = 5,      ///< i32
    Struct = 6,    ///< u16 field count + fields in declaration order
    List = 7,      ///< u32 count + values
    None = 8,      ///< empty std::optional
    Time = 9,      ///< i64 microseconds since the Unix epoch (UTC)
    Duration = 10, ///< i64 microseconds
};

const char* tagName(Tag t) noexcept;

/// Thrown when a message from the UI does not match the expected types.
class DecodeError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

class Writer;
class Reader;

namespace detail {

template <class T> struct is_vector : std::false_type {};
template <class T, class A> struct is_vector<std::vector<T, A>> : std::true_type {};
template <class T> struct is_optional : std::false_type {};
template <class T> struct is_optional<std::optional<T>> : std::true_type {};
template <class T> struct is_duration : std::false_type {};
template <class R, class P> struct is_duration<std::chrono::duration<R, P>> : std::true_type {};
template <class T> struct is_sys_time : std::false_type {};
template <class D> struct is_sys_time<std::chrono::time_point<std::chrono::system_clock, D>> : std::true_type {};
template <class> inline constexpr bool always_false = false;

/// Microseconds (the wire unit) in a duration, saturated to the int64 range:
/// coarse "never" sentinels such as hours::max() do not overflow.
template <class R, class P>
int64_t toMicros(std::chrono::duration<R, P> d) noexcept {
    using Q = std::ratio_divide<P, std::micro>;  // microseconds per tick
    constexpr int64_t hi = std::numeric_limits<int64_t>::max(), lo = std::numeric_limits<int64_t>::min();
    if constexpr (std::is_floating_point_v<R>) {
        const double us = static_cast<double>(d.count()) * static_cast<double>(Q::num) / static_cast<double>(Q::den);
        if (us != us) return 0;  // NaN
        if (us >= 0x1p63) return hi;
        if (us <= -0x1p63) return lo;
        return static_cast<int64_t>(us);
    } else {
        constexpr intmax_t lim = std::numeric_limits<intmax_t>::max() / Q::num;
        const R c = d.count();
        if (std::cmp_greater(c, lim)) return hi;
        if (std::cmp_less(c, -lim)) return lo;
        return static_cast<int64_t>(static_cast<intmax_t>(c) * Q::num / Q::den);
    }
}

/// A duration from wire microseconds; throws DecodeError if it does not fit
/// (e.g. a Dart DateTime in year 9999 for a nanosecond system_clock).
template <class D>
D fromMicros(int64_t us) {
    using Rep = typename D::rep;
    if constexpr (std::is_floating_point_v<Rep>) {
        return std::chrono::duration_cast<D>(std::chrono::duration<double, std::micro>(static_cast<double>(us)));
    } else {
        using Q = std::ratio_divide<std::micro, typename D::period>;  // ticks per microsecond
        constexpr intmax_t lim = std::numeric_limits<intmax_t>::max() / Q::num;
        const auto fail = [us] {
            throw DecodeError("nativebind: time or duration of " + std::to_string(us) +
                              " us is out of range for the C++ type");
        };
        if (us > lim || us < -lim) fail();
        const intmax_t ticks = static_cast<intmax_t>(us) * Q::num / Q::den;  // truncates like duration_cast
        if (!std::in_range<Rep>(ticks)) fail();
        return D(static_cast<Rep>(ticks));
    }
}

template <class T>
inline constexpr bool is_string_like =
    std::is_same_v<T, std::string> || std::is_same_v<T, std::string_view> || std::is_same_v<T, const char*> ||
    std::is_same_v<T, char*>;

/// Encoder/decoder for one struct type; emitted by the generator.
struct StructCodec {
    const char* name;
    void (*encode)(Writer&, const void*);
    void (*decode)(Reader&, void*);
};

void registerStructCodec(std::type_index type, const StructCodec& codec);
/// Throws std::logic_error if `type` was never registered.
const StructCodec& structCodec(std::type_index type);

}  // namespace detail

/// Wire tag of a C++ type (for schema checks). std::optional<T> reports T's tag.
template <class T>
constexpr Tag tagOf() {
    using U = std::remove_cv_t<T>;
    if constexpr (std::is_same_v<U, bool>) return Tag::Bool;
    else if constexpr (std::is_enum_v<U>) return Tag::Enum;
    else if constexpr (std::is_integral_v<U>) return Tag::Int;
    else if constexpr (std::is_floating_point_v<U>) return Tag::Double;
    else if constexpr (detail::is_string_like<U>) return Tag::String;
    else if constexpr (detail::is_vector<U>::value) return Tag::List;
    else if constexpr (detail::is_optional<U>::value) return tagOf<typename U::value_type>();
    else if constexpr (detail::is_sys_time<U>::value) return Tag::Time;
    else if constexpr (detail::is_duration<U>::value) return Tag::Duration;
    else if constexpr (std::is_class_v<U>) return Tag::Struct;
    else static_assert(detail::always_false<U>, "nativebind: unsupported type");
}

/// Appends encoded data to a byte vector.
class Writer {
public:
    explicit Writer(std::vector<uint8_t>& out) noexcept : out_(&out) {}

    void u8(uint8_t v) { out_->push_back(v); }
    void i8(int8_t v) { u8(static_cast<uint8_t>(v)); }
    void u16(uint16_t v) { raw(&v, sizeof v); }
    void u32(uint32_t v) { raw(&v, sizeof v); }
    void i32(int32_t v) { raw(&v, sizeof v); }
    void u64(uint64_t v) { raw(&v, sizeof v); }
    void i64(int64_t v) { raw(&v, sizeof v); }
    void f64(double v) { raw(&v, sizeof v); }
    void str(std::string_view s) {
        u32(static_cast<uint32_t>(s.size()));
        raw(s.data(), s.size());
    }
    void tag(Tag t) { u8(static_cast<uint8_t>(t)); }
    void beginStruct(uint16_t fieldCount) {
        tag(Tag::Struct);
        u16(fieldCount);
    }
    void bytes(const uint8_t* p, size_t n) { raw(p, n); }

    size_t size() const noexcept { return out_->size(); }
    void patchU32(size_t at, uint32_t v) noexcept { std::memcpy(out_->data() + at, &v, sizeof v); }

    /// Encodes any supported value with its tag.
    template <class T>
    void value(const T& v);

private:
    // resize + memcpy rather than insert(): GCC 12-16 at -O3 reports bogus
    // -Warray-bounds/-Wstringop-overflow for inlined vector range inserts.
    void raw(const void* p, size_t n) {
        if (n == 0) return;
        const size_t at = out_->size();
        out_->resize(at + n);
        std::memcpy(out_->data() + at, p, n);
    }
    std::vector<uint8_t>* out_;
};

/// Reads encoded data. Every read is bounds-checked and throws DecodeError.
class Reader {
public:
    Reader(const uint8_t* data, size_t len) noexcept : p_(data), end_(data + len) {}

    uint8_t u8() { return read<uint8_t>(); }
    int8_t i8() { return read<int8_t>(); }
    uint16_t u16() { return read<uint16_t>(); }
    uint32_t u32() { return read<uint32_t>(); }
    int32_t i32() { return read<int32_t>(); }
    uint64_t u64() { return read<uint64_t>(); }
    int64_t i64() { return read<int64_t>(); }
    double f64() { return read<double>(); }
    std::string str() {
        const uint32_t n = u32();
        need(n);
        std::string s(reinterpret_cast<const char*>(p_), n);
        p_ += n;
        return s;
    }
    Tag tag() { return static_cast<Tag>(u8()); }
    Tag peekTag() const {
        if (p_ == end_) throw DecodeError("nativebind: message truncated");
        return static_cast<Tag>(*p_);
    }
    void expect(Tag want) {
        const Tag got = tag();
        if (got != want) mismatch(want, got);
    }
    void beginStruct(uint16_t fieldCount) {
        expect(Tag::Struct);
        const uint16_t n = u16();
        if (n != fieldCount)
            throw DecodeError("nativebind: struct has " + std::to_string(n) + " fields, expected " +
                              std::to_string(fieldCount) + " (Dart and C++ out of sync? re-run nativebind generate)");
    }
    /// Throws if unread bytes remain (e.g. too many method arguments).
    void finish() const {
        if (p_ != end_) throw DecodeError("nativebind: unexpected extra data");
    }

    size_t remaining() const noexcept { return static_cast<size_t>(end_ - p_); }
    bool atEnd() const noexcept { return p_ == end_; }

    /// Decodes a tagged value of type T.
    template <class T>
    T value();

private:
    template <class T>
    T read() {
        need(sizeof(T));
        T v;
        std::memcpy(&v, p_, sizeof(T));
        p_ += sizeof(T);
        return v;
    }
    void need(size_t n) const {
        if (remaining() < n) throw DecodeError("nativebind: message truncated");
    }
    [[noreturn]] static void mismatch(Tag want, Tag got);

    const uint8_t* p_;
    const uint8_t* end_;
};

template <class T>
void Writer::value(const T& v) {
    using U = std::remove_cv_t<T>;
    using namespace std::chrono;
    if constexpr (std::is_same_v<U, bool>) {
        tag(Tag::Bool);
        u8(v ? 1 : 0);
    } else if constexpr (std::is_enum_v<U>) {
        tag(Tag::Enum);
        i32(static_cast<int32_t>(v));
    } else if constexpr (std::is_integral_v<U>) {
        tag(Tag::Int);
        i64(static_cast<int64_t>(v));
    } else if constexpr (std::is_floating_point_v<U>) {
        tag(Tag::Double);
        f64(static_cast<double>(v));
    } else if constexpr (detail::is_string_like<U>) {
        tag(Tag::String);
        str(std::string_view(v));
    } else if constexpr (detail::is_vector<U>::value) {
        tag(Tag::List);
        u32(static_cast<uint32_t>(v.size()));
        for (const auto& e : v) value(static_cast<const typename U::value_type&>(e));
    } else if constexpr (detail::is_optional<U>::value) {
        if (v) value(*v);
        else tag(Tag::None);
    } else if constexpr (detail::is_sys_time<U>::value) {
        tag(Tag::Time);
        i64(detail::toMicros(v.time_since_epoch()));
    } else if constexpr (detail::is_duration<U>::value) {
        tag(Tag::Duration);
        i64(detail::toMicros(v));
    } else if constexpr (std::is_class_v<U>) {
        detail::structCodec(typeid(U)).encode(*this, &v);
    } else {
        static_assert(detail::always_false<U>,
                      "nativebind: this type cannot cross the binding. Use bool, an integer, double, std::string, "
                      "an enum, a struct of those, std::vector, std::optional, or a std::chrono time/duration.");
    }
}

template <class T>
T Reader::value() {
    using U = std::remove_cv_t<T>;
    using namespace std::chrono;
    if constexpr (std::is_same_v<U, bool>) {
        expect(Tag::Bool);
        return u8() != 0;
    } else if constexpr (std::is_enum_v<U>) {
        expect(Tag::Enum);
        return static_cast<U>(i32());
    } else if constexpr (std::is_integral_v<U>) {
        expect(Tag::Int);
        const int64_t x = i64();
        if (!std::in_range<U>(x)) throw DecodeError("nativebind: integer " + std::to_string(x) + " out of range");
        return static_cast<U>(x);
    } else if constexpr (std::is_floating_point_v<U>) {
        const Tag t = tag();
        if (t == Tag::Double) return static_cast<U>(f64());
        if (t == Tag::Int) return static_cast<U>(i64());
        mismatch(Tag::Double, t);
    } else if constexpr (std::is_same_v<U, std::string>) {
        expect(Tag::String);
        return str();
    } else if constexpr (detail::is_vector<U>::value) {
        expect(Tag::List);
        const uint32_t n = u32();
        if (n > remaining()) throw DecodeError("nativebind: list length exceeds message");
        U out;
        out.reserve(n);
        for (uint32_t i = 0; i < n; ++i) out.push_back(value<typename U::value_type>());
        return out;
    } else if constexpr (detail::is_optional<U>::value) {
        if (peekTag() == Tag::None) {
            tag();
            return std::nullopt;
        }
        return U(value<typename U::value_type>());
    } else if constexpr (detail::is_sys_time<U>::value) {
        expect(Tag::Time);
        return U(detail::fromMicros<typename U::duration>(i64()));
    } else if constexpr (detail::is_duration<U>::value) {
        expect(Tag::Duration);
        return detail::fromMicros<U>(i64());
    } else if constexpr (std::is_class_v<U>) {
        static_assert(std::is_default_constructible_v<U>, "nativebind: structs that cross the binding need a default constructor");
        U out{};
        detail::structCodec(typeid(U)).decode(*this, &out);
        return out;
    } else {
        static_assert(detail::always_false<U>, "nativebind: this type cannot be decoded");
    }
}

}  // namespace nativebind
