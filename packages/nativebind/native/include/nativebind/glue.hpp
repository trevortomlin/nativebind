#pragma once
// Interface between generated code (`*.nb.cpp`, written by
// `nativebind_generator`) and the runtime. Application code never uses
// this header directly.

#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <tuple>
#include <type_traits>
#include <typeinfo>

#include "nativebind/codec.hpp"
#include "nativebind/module.hpp"
#include "nativebind/signal.hpp"
#include "nativebind/types.hpp"

namespace nativebind {

/// Thrown when the Guard denies a UI write or invoke.
class AccessDenied : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

namespace glue {

/// Name and wire type of one property, in declaration order. The runtime
/// checks a module's actual members against this list when adopting it.
struct PropDecl {
    const char* name;
    Tag tag;
};

/// Everything the runtime knows about one module class.
struct ModuleType {
    const char* name;
    const std::type_info* cppType;
    bool instanced;
    /// Creation order of singletons (ModuleOptions::order).
    int order;
    /// Default factory for singletons; null for instanced types.
    std::unique_ptr<Module> (*create)();
    /// Decodes arguments, calls method `method` and encodes its result.
    void (*invoke)(Module& self, uint16_t method, Reader& args, Writer& result);
    const PropDecl* props;
    uint16_t propCount;
    uint16_t listCount;
    uint16_t signalCount;
    uint16_t methodCount;
    /// Canonical schema text; Dart compares it to detect stale generated code.
    const char* schema;
};

/// Static registration of a module type (one per generated file).
struct Registrar {
    explicit Registrar(const ModuleType& type);
};

/// Specialized by generated code for each module class. NATIVEBIND_MODULE makes
/// it a friend, so private NATIVEBIND_INVOKE methods can be called.
template <class T>
struct Invoker;

template <class T>
std::unique_ptr<Module> create() {
    return std::unique_ptr<Module>(new T());
}

/// The default factory, or null if T is instanced or not default-constructible.
template <class T>
constexpr auto factoryFor(bool instanced) -> std::unique_ptr<Module> (*)() {
    if constexpr (std::is_default_constructible_v<T>) return instanced ? nullptr : &create<T>;
    else return nullptr;
}

/// Throws AccessDenied unless the Guard allows calling `method` with this
/// NATIVEBIND_INVOKE_AS permission (refused when no guard is installed).
void requirePermission(const char* module, const char* method, int64_t permission);

/// Storage type used to decode a parameter of type A.
template <class A>
struct ArgStorage {
    using type = std::decay_t<A>;
};
template <class A>
    requires std::is_same_v<std::decay_t<A>, std::string_view>
struct ArgStorage<A> {
    using type = std::string;
};

template <class R, class... A, class F>
void callWith(F&& f, Reader& args, Writer& result) {
    // Braced initialization evaluates the decoders left to right.
    std::tuple<typename ArgStorage<A>::type...> values{args.value<typename ArgStorage<A>::type>()...};
    args.finish();
    if constexpr (std::is_void_v<R>) {
        std::apply(f, values);
    } else {
        result.value(std::apply(f, values));
    }
}

/// Decodes the arguments of a member function from `args`, calls it on `self`
/// and encodes its result. Generated code calls this with `&Class::method`, so
/// parameter and return types come from the compiler, not the generator.
template <class S, class C, class R, class... A>
void call(S& self, R (C::*fn)(A...), Reader& args, Writer& result) {
    callWith<R, A...>([&](auto&... a) -> R { return (self.*fn)(a...); }, args, result);
}
template <class S, class C, class R, class... A>
void call(S& self, R (C::*fn)(A...) const, Reader& args, Writer& result) {
    callWith<R, A...>([&](auto&... a) -> R { return (self.*fn)(a...); }, args, result);
}
template <class S, class C, class R, class... A>
void call(S& self, R (C::*fn)(A...) noexcept, Reader& args, Writer& result) {
    callWith<R, A...>([&](auto&... a) -> R { return (self.*fn)(a...); }, args, result);
}
template <class S, class C, class R, class... A>
void call(S& self, R (C::*fn)(A...) const noexcept, Reader& args, Writer& result) {
    callWith<R, A...>([&](auto&... a) -> R { return (self.*fn)(a...); }, args, result);
}

[[noreturn]] void unknownMethod(const char* module, uint16_t method);

// ------------------------------------------------------------------ shapes
//
// The wire shape of a C++ type as a type, so the generated code can check
// with static_assert that the generator read every property, list item,
// struct field, signal argument, parameter and return type the way the
// compiler does, nested types included. All integer types are Int.

namespace shape {
struct Void {};
struct Bool {};
struct Int {};
struct Double {};
struct String {};
struct Time {};
struct Duration {};
struct Any {};  ///< in Enum<Any> / Struct<Any>: a type the generator did not see declared
template <class T>
struct List {};
template <class T>
struct Optional {};
template <class E>
struct Enum {};
template <class S>
struct Struct {};
template <class... A>
struct Args {};
template <class R, class A>
struct Fn {};
}  // namespace shape

namespace shapes {
template <class T>
auto shapeOf() {
    using U = std::remove_cvref_t<T>;
    if constexpr (std::is_void_v<U>) return shape::Void{};
    else if constexpr (std::is_same_v<U, bool>) return shape::Bool{};
    else if constexpr (std::is_enum_v<U>) return shape::Enum<U>{};
    else if constexpr (std::is_integral_v<U>) return shape::Int{};
    else if constexpr (std::is_floating_point_v<U>) return shape::Double{};
    else if constexpr (::nativebind::detail::is_string_like<U>) return shape::String{};
    else if constexpr (::nativebind::detail::is_vector<U>::value) return shape::List<decltype(shapeOf<typename U::value_type>())>{};
    else if constexpr (::nativebind::detail::is_optional<U>::value) return shape::Optional<decltype(shapeOf<typename U::value_type>())>{};
    else if constexpr (::nativebind::detail::is_sys_time<U>::value) return shape::Time{};
    else if constexpr (::nativebind::detail::is_duration<U>::value) return shape::Duration{};
    else return shape::Struct<U>{};
}

template <class F>
struct MethodShape;
template <class C, class R, class... A>
struct MethodShape<R (C::*)(A...)> {
    using type = shape::Fn<decltype(shapeOf<R>()), shape::Args<decltype(shapeOf<A>())...>>;
};
template <class C, class R, class... A>
struct MethodShape<R (C::*)(A...) const> : MethodShape<R (C::*)(A...)> {};
template <class C, class R, class... A>
struct MethodShape<R (C::*)(A...) noexcept> : MethodShape<R (C::*)(A...)> {};
template <class C, class R, class... A>
struct MethodShape<R (C::*)(A...) const noexcept> : MethodShape<R (C::*)(A...)> {};

template <class S>
struct SignalShape;
template <class... A>
struct SignalShape<Signal<A...>> {
    using type = shape::Args<decltype(shapeOf<A>())...>;
};

/// Actual shape A matches expected shape E (Any stands for any enum or struct).
template <class A, class E>
struct Matches : std::is_same<A, E> {};
template <class S>
struct Matches<shape::Enum<S>, shape::Enum<shape::Any>> : std::bool_constant<std::is_enum_v<S>> {};
template <class S>
struct Matches<shape::Struct<S>, shape::Struct<shape::Any>> : std::true_type {};
template <class A, class E>
struct Matches<shape::List<A>, shape::List<E>> : Matches<A, E> {};
template <class A, class E>
struct Matches<shape::Optional<A>, shape::Optional<E>> : Matches<A, E> {};
template <class... A, class... E>
    requires(sizeof...(A) == sizeof...(E))
struct Matches<shape::Args<A...>, shape::Args<E...>> : std::bool_constant<(Matches<A, E>::value && ...)> {};
template <class R, class A, class Q, class E>
struct Matches<shape::Fn<R, A>, shape::Fn<Q, E>> : std::bool_constant<Matches<R, Q>::value && Matches<A, E>::value> {};
}  // namespace shapes

/// The C++ type T has wire shape E.
template <class T, class E>
inline constexpr bool hasShape = shapes::Matches<decltype(shapes::shapeOf<T>()), E>::value;
/// The member function `fn` (any cv/noexcept) has shape E (shape::Fn<R, Args<...>>).
template <auto fn, class E>
inline constexpr bool methodHasShape = shapes::Matches<typename shapes::MethodShape<decltype(fn)>::type, E>::value;
/// The signal type S (Signal<A...>) has argument shape E (shape::Args<...>).
template <class S, class E>
inline constexpr bool signalHasShape = shapes::Matches<typename shapes::SignalShape<S>::type, E>::value;

/// Static registration of a struct codec.
template <class T>
struct StructRegistrar {
    StructRegistrar(const char* name, void (*encode)(Writer&, const void*), void (*decode)(Reader&, void*)) {
        detail::registerStructCodec(typeid(T), detail::StructCodec{name, encode, decode});
    }
};

}  // namespace glue
}  // namespace nativebind
