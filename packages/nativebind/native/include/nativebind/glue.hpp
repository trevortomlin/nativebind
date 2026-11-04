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

/// Static registration of a struct codec.
template <class T>
struct StructRegistrar {
    StructRegistrar(const char* name, void (*encode)(Writer&, const void*), void (*decode)(Reader&, void*)) {
        detail::registerStructCodec(typeid(T), detail::StructCodec{name, encode, decode});
    }
};

}  // namespace glue
}  // namespace nativebind
