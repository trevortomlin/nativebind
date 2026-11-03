#include "nativebind/codec.hpp"

#include <mutex>
#include <unordered_map>

namespace nativebind {

const char* tagName(Tag t) noexcept {
    switch (t) {
        case Tag::Void: return "void";
        case Tag::Bool: return "bool";
        case Tag::Int: return "int";
        case Tag::Double: return "double";
        case Tag::String: return "string";
        case Tag::Enum: return "enum";
        case Tag::Struct: return "struct";
        case Tag::List: return "list";
        case Tag::None: return "none";
        case Tag::Time: return "time";
        case Tag::Duration: return "duration";
    }
    return "unknown";
}

void Reader::mismatch(Tag want, Tag got) {
    throw DecodeError(std::string("nativebind: expected ") + tagName(want) + ", got " + tagName(got));
}

namespace detail {
namespace {

struct StructRegistry {
    std::mutex mutex;
    std::unordered_map<std::type_index, StructCodec> codecs;
};

StructRegistry& structRegistry() {
    static StructRegistry registry;
    return registry;
}

}  // namespace

void registerStructCodec(std::type_index type, const StructCodec& codec) {
    auto& r = structRegistry();
    std::lock_guard g(r.mutex);
    r.codecs.insert_or_assign(type, codec);
}

const StructCodec& structCodec(std::type_index type) {
    auto& r = structRegistry();
    std::lock_guard g(r.mutex);
    auto it = r.codecs.find(type);
    if (it == r.codecs.end())
        throw std::logic_error(std::string("nativebind: struct ") + type.name() +
                               " has no codec. Structs crossing the binding must be defined in a module file "
                               "processed by nativebind generate.");
    return it->second;  // unordered_map references stay valid across inserts
}

}  // namespace detail
}  // namespace nativebind
