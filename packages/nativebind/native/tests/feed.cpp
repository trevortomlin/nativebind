#include "feed.hpp"

#include <algorithm>
#include <stdexcept>

#include "nativebind/runtime.hpp"

namespace feed {

Value readValue(nativebind::Reader& r) {
    Value v;
    v.tag = r.tag();
    switch (v.tag) {
        case Tag::Void:
        case Tag::None: break;
        case Tag::Bool: v.b = r.u8() != 0; break;
        case Tag::Int:
        case Tag::Time:
        case Tag::Duration: v.i = r.i64(); break;
        case Tag::Enum: v.i = r.i32(); break;
        case Tag::Double: v.d = r.f64(); break;
        case Tag::String: v.s = r.str(); break;
        case Tag::Struct: {
            const uint16_t n = r.u16();
            for (uint16_t k = 0; k < n; ++k) v.items.push_back(readValue(r));
            break;
        }
        case Tag::List: {
            const uint32_t n = r.u32();
            for (uint32_t k = 0; k < n; ++k) v.items.push_back(readValue(r));
            break;
        }
        default: throw nativebind::DecodeError("feed: unknown tag " + std::to_string(static_cast<int>(v.tag)));
    }
    return v;
}

std::string describe(const Value& v) {
    switch (v.tag) {
        case Tag::Void: return "void";
        case Tag::None: return "none";
        case Tag::Bool: return v.b ? "true" : "false";
        case Tag::Int: return std::to_string(v.i);
        case Tag::Enum: return "enum(" + std::to_string(v.i) + ")";
        case Tag::Time: return "time(" + std::to_string(v.i) + ")";
        case Tag::Duration: return "duration(" + std::to_string(v.i) + ")";
        case Tag::Double: return std::to_string(v.d);
        case Tag::String: return "\"" + v.s + "\"";
        case Tag::Struct:
        case Tag::List: {
            std::string s = v.tag == Tag::List ? "[" : "{";
            for (size_t k = 0; k < v.items.size(); ++k) s += (k ? ", " : "") + describe(v.items[k]);
            return s + (v.tag == Tag::List ? "]" : "}");
        }
    }
    return "?";
}

std::vector<Record> decode(const uint8_t* data, size_t len) {
    std::vector<Record> out;
    nativebind::Reader top(data, len);
    while (!top.atEnd()) {
        Record rec;
        rec.kind = static_cast<Rec>(top.u8());
        const uint32_t size = top.u32();
        if (size > top.remaining()) throw nativebind::DecodeError("feed: record overruns buffer");
        const uint8_t* body = data + (len - top.remaining());
        nativebind::Reader r(body, size);
        for (uint32_t k = 0; k < size; ++k) top.u8();  // skip body in the outer reader

        switch (rec.kind) {
            case Rec::Resync: break;
            case Rec::InstanceAdded:
                rec.instance = r.u32();
                rec.type = r.u16();
                rec.key = r.u64();
                break;
            case Rec::InstanceRemoved: rec.instance = r.u32(); break;
            case Rec::Prop:
                rec.instance = r.u32();
                rec.member = r.u16();
                rec.seq = r.u32();
                rec.values.push_back(readValue(r));
                break;
            case Rec::Meta:
                rec.instance = r.u32();
                rec.member = r.u16();
                rec.min = r.f64();
                rec.max = r.f64();
                rec.step = r.f64();
                rec.flags = r.u8();
                rec.label = r.str();
                for (uint16_t n = r.u16(); n > 0; --n) {
                    std::string key = r.str();
                    rec.attrs.emplace_back(std::move(key), readValue(r));
                }
                break;
            case Rec::ListReset: {
                rec.instance = r.u32();
                rec.member = r.u16();
                rec.version = r.u32();
                rec.count = r.u32();
                for (uint32_t k = 0; k < rec.count; ++k) rec.values.push_back(readValue(r));
                break;
            }
            case Rec::ListInsert:
                rec.instance = r.u32();
                rec.member = r.u16();
                rec.version = r.u32();
                rec.index = r.u32();
                rec.values.push_back(readValue(r));
                break;
            case Rec::ListRemove:
                rec.instance = r.u32();
                rec.member = r.u16();
                rec.version = r.u32();
                rec.index = r.u32();
                rec.count = r.u32();
                break;
            case Rec::ListUpdate:
                rec.instance = r.u32();
                rec.member = r.u16();
                rec.version = r.u32();
                rec.index = r.u32();
                rec.values.push_back(readValue(r));
                break;
            case Rec::ListMove:
                rec.instance = r.u32();
                rec.member = r.u16();
                rec.version = r.u32();
                rec.from = r.u32();
                rec.to = r.u32();
                break;
            case Rec::Signal: {
                rec.instance = r.u32();
                rec.member = r.u16();
                const uint8_t argc = r.u8();
                for (uint8_t k = 0; k < argc; ++k) rec.values.push_back(readValue(r));
                break;
            }
            case Rec::Result:
                rec.callId = r.u32();
                rec.status = r.i32();
                if (rec.status == NATIVEBIND_OK) rec.values.push_back(readValue(r));
                else rec.error = r.str();
                break;
            default: continue;  // unknown kinds are skipped (forward compatible)
        }
        r.finish();
        out.push_back(std::move(rec));
    }
    return out;
}

void Mirror::apply(const std::vector<Record>& records) {
    for (const Record& rec : records) {
        switch (rec.kind) {
            case Rec::Resync:
                instances.clear();
                ++resyncs;
                break;
            case Rec::InstanceAdded: {
                auto& inst = instances[rec.instance];  // idempotent
                inst.type = rec.type;
                inst.key = rec.key;
                break;
            }
            case Rec::InstanceRemoved: instances.erase(rec.instance); break;
            case Rec::Prop: {
                auto it = instances.find(rec.instance);
                if (it == instances.end()) break;
                auto& p = it->second.props[rec.member];
                p.value = rec.values.at(0);
                p.seq = rec.seq;
                break;
            }
            case Rec::Meta: {
                auto it = instances.find(rec.instance);
                if (it == instances.end()) break;
                it->second.props[rec.member].meta =
                    MetaState{rec.min, rec.max, rec.step, rec.flags, rec.label, rec.attrs};
                break;
            }
            case Rec::ListReset: {
                auto it = instances.find(rec.instance);
                if (it == instances.end()) break;
                auto& l = it->second.lists[rec.member];
                l.version = rec.version;
                l.items = rec.values;
                break;
            }
            case Rec::ListInsert:
            case Rec::ListRemove:
            case Rec::ListUpdate:
            case Rec::ListMove: {
                auto it = instances.find(rec.instance);
                if (it == instances.end()) break;
                auto& l = it->second.lists[rec.member];
                if (rec.version <= l.version) break;  // already contained in a reset
                if (rec.version != l.version + 1) {
                    ++gaps;
                    break;
                }
                l.version = rec.version;
                auto at = [&](uint32_t i) { return l.items.begin() + static_cast<std::ptrdiff_t>(i); };
                if (rec.kind == Rec::ListInsert) l.items.insert(at(rec.index), rec.values.at(0));
                else if (rec.kind == Rec::ListRemove) l.items.erase(at(rec.index), at(rec.index + rec.count));
                else if (rec.kind == Rec::ListUpdate) l.items.at(rec.index) = rec.values.at(0);
                else {
                    Value v = l.items.at(rec.from);
                    l.items.erase(at(rec.from));
                    l.items.insert(at(rec.to), v);
                }
                break;
            }
            case Rec::Signal: signals.push_back(rec); break;
            case Rec::Result: results.push_back(rec); break;
        }
    }
}

const InstanceState* Mirror::find(uint32_t handle) const {
    auto it = instances.find(handle);
    return it == instances.end() ? nullptr : &it->second;
}

Consumer::Consumer() { nativebind_attach_callback(&Consumer::onWake, this); }

void Consumer::onWake(void* self) { static_cast<Consumer*>(self)->wakes_.fetch_add(1); }

std::vector<Record> Consumer::pump() {
    uint32_t len = 0;
    const uint8_t* data = nativebind_drain(&len);
    auto records = decode(data, len);
    mirror.apply(records);
    return records;
}

std::vector<Record> Consumer::settle() {
    if (nativebind_flush(5000) != NATIVEBIND_OK) throw std::runtime_error("flush timed out");
    return pump();
}

Started::Started() { nativebind::start(); }
Started::~Started() {
    nativebind_attach_callback(nullptr, nullptr);
    nativebind::stop();
}

std::vector<Record> only(const std::vector<Record>& records, Rec kind) {
    std::vector<Record> out;
    std::copy_if(records.begin(), records.end(), std::back_inserter(out), [kind](const Record& r) { return r.kind == kind; });
    return out;
}

}  // namespace feed
