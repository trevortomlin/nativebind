#pragma once
// Property metadata and module options. Everything here crosses to Dart and is
// part of the wire format.

#include <concepts>
#include <cstdint>
#include <limits>
#include <string>
#include <type_traits>
#include <variant>
#include <vector>

namespace nativebind {

inline constexpr double kUnbounded = std::numeric_limits<double>::infinity();

/// Value of a metadata attribute: bool, integer (enums are sent as their
/// integer value), double or string.
class AttrValue {
public:
    using Variant = std::variant<bool, int64_t, double, std::string>;

    AttrValue(bool v) : v_(v) {}  // NOLINT(google-explicit-constructor)
    AttrValue(double v) : v_(v) {}  // NOLINT
    AttrValue(const char* v) : v_(std::string(v)) {}  // NOLINT
    AttrValue(std::string v) : v_(std::move(v)) {}  // NOLINT
    template <class T>
        requires((std::integral<T> && !std::same_as<T, bool>) || std::is_enum_v<T>)
    AttrValue(T v) : v_(static_cast<int64_t>(v)) {}  // NOLINT

    const Variant& get() const noexcept { return v_; }
    bool operator==(const AttrValue&) const = default;

private:
    Variant v_;
};

/// A metadata attribute for layers above nativebind (display units, required
/// permission, ...). nativebind sends it to Dart unchanged and never reads it.
struct Attr {
    std::string key;
    AttrValue value;
    bool operator==(const Attr&) const = default;
};

using Attrs = std::vector<Attr>;

/// Metadata of a bound property, written with designated initializers in
/// declaration order:
///
///     NATIVEBIND_PROP(double, volume, 0.5, .min = 0, .max = 1, .step = 0.05,
///                     .attrs = {{"unit", "%"}})
///
/// The range is enforced on writes from the UI; values set by C++ (e.g. measured
/// values) are never clamped.
struct Meta {
    double min = -kUnbounded;
    double max = kUnbounded;
    double step = 0;              ///< UI increment; 0 = continuous (or 1 for integers)
    const char* label = nullptr;  ///< display name; null = derived from the member name
    Attrs attrs = {};             ///< for layers above nativebind; see Attr
};

/// Options of NATIVEBIND_MODULE.
struct ModuleOptions {
    /// false: exactly one instance, created when nativebind starts.
    /// true: any number of instances, created with nativebind::spawn<T>(key, ...).
    bool instanced = false;
    /// Singletons are created in ascending order and destroyed in reverse.
    /// Infrastructure that other modules use while shutting down (e.g. a
    /// logging or settings service) takes a negative order.
    int order = 0;
};

}  // namespace nativebind
