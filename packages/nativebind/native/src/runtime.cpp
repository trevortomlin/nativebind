#include "runtime.hpp"

#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <future>
#include <stdexcept>

#include "nativebind/nativebind.h"
#include "nativebind/runtime.hpp"

#if NATIVEBIND_WITH_DART
#include "dart_api_dl.h"
#endif

namespace nativebind {
namespace detail {

namespace {

constexpr size_t kMaxEventBytes = size_t{4} << 20;  // beyond this the consumer gets a resync instead

std::atomic<LogHandler> gLogHandler{nullptr};
std::atomic<uint32_t> gNextHandle{0};
std::atomic<uint64_t> gNextTimer{0};
std::atomic<bool> gRuntimeAlive{false};
thread_local std::string tlsError;

}  // namespace

void setLastError(std::string message) { tlsError = std::move(message); }
const char* lastError() noexcept { return tlsError.c_str(); }

void logf(const char* fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    std::vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (LogHandler h = gLogHandler.load()) h(buf);
    else std::fprintf(stderr, "[nativebind] %s\n", buf);
}

// ------------------------------------------------------------------ lifecycle

Runtime& Runtime::get() {
    static Runtime runtime;
    gRuntimeAlive.store(true);
    return runtime;
}

Runtime::~Runtime() {
    try {
        stop();
    } catch (...) {
    }
    gRuntimeAlive.store(false);
}

void Runtime::runSync(const std::function<void()>& fn) {
    if (loop_.onThread()) {
        fn();
        return;
    }
    std::promise<void> done;
    auto result = done.get_future();
    loop_.post([&] {
        try {
            fn();
            done.set_value();
        } catch (...) {
            done.set_exception(std::current_exception());
        }
    });
    result.get();
}

void Runtime::start() {
    std::lock_guard lk(lifecycle_);
    if (started_) return;
    loop_.start();
    touch();
    started_ = true;
    runSync([this] {
        std::vector<const glue::ModuleType*> types;
        {
            std::lock_guard g(typesMutex_);
            types = types_;
        }
        // ModuleOptions::order: lower first, so it is destroyed last (e.g. a
        // logging service that other modules still use while shutting down).
        std::stable_sort(types.begin(), types.end(),
                         [](const glue::ModuleType* a, const glue::ModuleType* b) { return a->order < b->order; });
        std::vector<Module*> created;
        for (const glue::ModuleType* t : types) {
            if (t->instanced) continue;
            if (!t->create) {
                logf("module %s: a singleton needs a default constructor (or declare .instanced = true)", t->name);
                continue;
            }
            try {
                std::unique_ptr<Module> m = t->create();
                std::unique_lock reg(registry_);
                created.push_back(&registerLocked(*t, std::move(m), 0));
            } catch (const std::exception& e) {
                logf("creating module %s failed: %s", t->name, e.what());
            }
        }
        for (Module* m : created) runGuarded([m] { m->onStart(); }, m->type_->name);
    });
}

void Runtime::stop() {
    std::lock_guard lk(lifecycle_);
    if (!started_) return;
    runSync([this] {
        std::vector<uint32_t> handles;
        {
            // From here on spawn() is refused: an instance created after this
            // snapshot would never be stopped and would outlive the run.
            std::unique_lock reg(registry_);
            stopping_ = true;
            handles = order_;
        }
        for (auto it = handles.rbegin(); it != handles.rend(); ++it) {
            Module* m;
            {
                std::shared_lock reg(registry_);
                m = findLocked(*it);
            }
            if (m) runGuarded([m] { m->onStop(); }, m->type_->name);
        }
        for (auto it = handles.rbegin(); it != handles.rend(); ++it) destroyNow(*it, false);
    });
    started_ = false;
    {
        std::unique_lock reg(registry_);
        stopping_ = false;
    }
    loop_.stop();
    {
        std::lock_guard g(eventsMutex_);
        events_.clear();
        results_.clear();
    }
    {
        std::lock_guard g(dirtyMutex_);
        dirtyProps_.clear();
        dirtyMeta_.clear();
    }
    {
        std::lock_guard g(pendingMutex_);
        pendingTimers_.clear();
    }
    resync_ = true;
    setGuard(nullptr);
}

bool Runtime::flush(std::chrono::milliseconds timeout) {
    if (!loop_.running() || loop_.onThread()) return true;
    auto done = std::make_shared<std::promise<void>>();
    auto result = done->get_future();
    loop_.post([done] { done->set_value(); });
    return result.wait_for(timeout) == std::future_status::ready;
}

// ------------------------------------------------------------------ types

void Runtime::registerType(const glue::ModuleType& type) {
    std::lock_guard g(typesMutex_);
    const std::type_index key(*type.cppType);
    if (typeIndex_.count(key)) {
        logf("module %s registered twice (is its .nb.cpp compiled twice?)", type.name);
        return;
    }
    for (const auto* t : types_)
        if (std::strcmp(t->name, type.name) == 0) {
            logf("two module classes are named %s; module names must be unique", type.name);
            return;
        }
    typeIndex_.emplace(key, static_cast<uint16_t>(types_.size()));
    types_.push_back(&type);
}

int Runtime::typeCount() const {
    std::lock_guard g(typesMutex_);
    return static_cast<int>(types_.size());
}

int Runtime::typeId(std::string_view name) const {
    std::lock_guard g(typesMutex_);
    for (size_t i = 0; i < types_.size(); ++i)
        if (name == types_[i]->name) return static_cast<int>(i);
    return NATIVEBIND_E_UNKNOWN_TYPE;
}

const glue::ModuleType* Runtime::type(int id) const {
    std::lock_guard g(typesMutex_);
    if (id < 0 || static_cast<size_t>(id) >= types_.size()) return nullptr;
    return types_[static_cast<size_t>(id)];
}

const glue::ModuleType* Runtime::typeFor(const std::type_info& t) const {
    std::lock_guard g(typesMutex_);
    auto it = typeIndex_.find(std::type_index(t));
    return it == typeIndex_.end() ? nullptr : types_[it->second];
}

// ------------------------------------------------------------------ instances

Module* Runtime::findLocked(uint32_t handle) const {
    auto it = instances_.find(handle);
    return it == instances_.end() ? nullptr : it->second.get();
}

bool Runtime::isLive(uint32_t handle) const {
    std::shared_lock reg(registry_);
    const Module* m = findLocked(handle);
    return m && m->live();
}

Module& Runtime::registerLocked(const glue::ModuleType& type, std::unique_ptr<Module> module, uint64_t key) {
    Module& m = *module;
    // The generated glue and the class must agree, or indexes would be wrong.
    auto fail = [&](const std::string& what) {
        throw std::logic_error(std::string("module ") + type.name + ": " + what +
                               " does not match the generated code; rebuild the library so nativebind_generator regenerates "
                               "its glue (nativebind_add_modules does this)");
    };
    if (m.props_.size() != type.propCount) fail("property count");
    for (size_t i = 0; i < m.props_.size(); ++i) {
        if (std::strcmp(m.props_[i]->name(), type.props[i].name) != 0) fail(std::string("property ") + m.props_[i]->name());
        if (m.props_[i]->wireTag() != type.props[i].tag) fail(std::string("type of property ") + m.props_[i]->name());
    }
    if (m.lists_.size() != type.listCount) fail("list count");
    if (m.signals_.size() != type.signalCount) fail("signal count");
    if (type.instanced)
        for (const auto& [h, other] : instances_)
            if (other->type_ == &type && other->key_ == key)
                throw std::invalid_argument(std::string("nativebind::spawn: ") + type.name + " key " + std::to_string(key) +
                                            " already exists");

    m.type_ = &type;
    m.key_ = key;
    {
        std::lock_guard g(typesMutex_);
        m.typeId_ = typeIndex_.at(std::type_index(*type.cppType));
    }
    const uint32_t handle = m.handle_;
    instances_.emplace(handle, std::move(module));
    order_.push_back(handle);
    m.live_.store(true, std::memory_order_release);

    event(Rec::InstanceAdded, [&](Writer& w) {
        w.u32(handle);
        w.u16(m.typeId_);
        w.u64(key);
    });
    for (ListBase* l : m.lists_) l->goLive();
    for (PropBase* p : m.props_) {
        metaChanged(*p);
        propChanged(*p);
    }
    armPending(m);
    return m;
}

Module& Runtime::adopt(const std::type_info& t, std::unique_ptr<Module> module, uint64_t key) {
    if (!started_) throw std::logic_error("nativebind::spawn: the runtime is not started");
    const glue::ModuleType* type = typeFor(t);
    if (!type)
        throw std::logic_error(std::string("nativebind::spawn: ") + t.name() +
                               " is not a registered module (is its .nb.cpp part of the library?)");
    if (!type->instanced)
        throw std::logic_error(std::string("nativebind::spawn: ") + type->name +
                               " is a singleton; declare NATIVEBIND_MODULE(" + type->name + ", .instanced = true)");
    Module* m;
    {
        std::unique_lock reg(registry_);
        if (stopping_) throw std::logic_error(std::string("nativebind::spawn: ") + type->name + ": the runtime is stopping");
        m = &registerLocked(*type, std::move(module), key);
    }
    postFor(m->handle_, [m] { runGuarded([m] { m->onStart(); }, m->type_->name); }, {});
    return *m;
}

Module& Runtime::singleton(const std::type_info& t) {
    const glue::ModuleType* type = typeFor(t);
    if (!type) throw std::logic_error(std::string("nativebind::singleton: ") + t.name() + " is not a registered module");
    std::shared_lock reg(registry_);
    for (uint32_t h : order_) {
        Module* m = findLocked(h);
        if (m && m->type_ == type) return *m;
    }
    throw std::logic_error(std::string("nativebind::singleton: no ") + type->name + " (is the runtime started?)");
}

std::vector<Module*> Runtime::instances(const std::type_info& t) {
    const glue::ModuleType* type = typeFor(t);
    std::vector<Module*> out;
    if (!type) return out;
    {
        std::shared_lock reg(registry_);
        for (uint32_t h : order_) {
            Module* m = findLocked(h);
            if (m && m->type_ == type && m->live()) out.push_back(m);
        }
    }
    std::stable_sort(out.begin(), out.end(), [](const Module* a, const Module* b) { return a->key_ < b->key_; });
    return out;
}

void Runtime::destroy(uint32_t handle) {
    if (!started_) return;
    loop_.post([this, handle] { destroyNow(handle, true); });
}

void Runtime::destroyNow(uint32_t handle, bool callStop) {
    Module* m;
    {
        std::shared_lock reg(registry_);
        m = findLocked(handle);
    }
    if (!m || !m->live()) return;
    if (callStop) runGuarded([m] { m->onStop(); }, m->type_->name);

    std::unique_ptr<Module> owned;
    {
        std::unique_lock reg(registry_);
        auto it = instances_.find(handle);
        if (it == instances_.end()) return;
        {
            std::lock_guard g(dirtyMutex_);
            m->live_.store(false, std::memory_order_release);
            auto ownedBy = [m](PropBase* p) { return &p->owner() == m; };
            std::erase_if(dirtyProps_, ownedBy);
            std::erase_if(dirtyMeta_, ownedBy);
            for (PropBase* p : m->props_) {
                p->dirty_ = false;
                p->metaDirty_ = false;
            }
        }
        for (ListBase* l : m->lists_) l->goDead();
        owned = std::move(it->second);
        instances_.erase(it);
        std::erase(order_, handle);
        event(Rec::InstanceRemoved, [&](Writer& w) { w.u32(handle); });
    }
    loop_.cancelOwner(handle);
    {
        std::lock_guard g(pendingMutex_);
        pendingTimers_.erase(handle);
    }
    owned->endConnections();  // waits for its listeners running on other threads
    owned.reset();
}

// ------------------------------------------------------------------ timers

void Runtime::armTimer(Module& owner, TimerId id, std::chrono::milliseconds delay, std::chrono::milliseconds period,
                       std::function<void()> fn) {
    const uint32_t h = owner.handle();
    auto guarded = [this, h, fn = std::move(fn)] {
        if (isLive(h)) fn();
    };
    {
        std::lock_guard g(pendingMutex_);
        if (!owner.live()) {
            pendingTimers_[h].push_back(PendingTimer{id, delay, period, std::move(guarded)});
            return;
        }
    }
    loop_.addTimer(id, h, delay, period, std::move(guarded));
}

void Runtime::armPending(Module& m) {
    std::vector<PendingTimer> timers;
    {
        std::lock_guard g(pendingMutex_);
        auto it = pendingTimers_.find(m.handle_);
        if (it == pendingTimers_.end()) return;
        timers = std::move(it->second);
        pendingTimers_.erase(it);
    }
    for (auto& t : timers) loop_.addTimer(t.id, m.handle_, t.delay, t.period, std::move(t.fn));
}

void Runtime::cancelTimer(TimerId id) {
    loop_.cancel(id);
    std::lock_guard g(pendingMutex_);
    for (auto& [h, timers] : pendingTimers_) std::erase_if(timers, [id](const PendingTimer& t) { return t.id == id; });
}

void Runtime::moduleGone(uint32_t handle) noexcept {
    std::lock_guard g(pendingMutex_);
    pendingTimers_.erase(handle);
}

void Runtime::postFor(uint32_t handle, std::function<void()> fn, std::function<void()> dropped) {
    loop_.post([this, handle, fn = std::move(fn), dropped = std::move(dropped)] {
        if (isLive(handle)) fn();
        else if (dropped) dropped();
    });
}

// ------------------------------------------------------------------ change feed

void Runtime::wake() {
    if (wakePending_.exchange(true)) return;
    std::lock_guard g(wakeMutex_);
#if NATIVEBIND_WITH_DART
    if (port_ != 0) {
        if (Dart_PostInteger_DL) Dart_PostInteger_DL(port_, 0);
        return;
    }
#endif
    if (wakeCallback_) wakeCallback_(wakeUser_);
}

void Runtime::attachPort(int64_t port) {
    {
        std::lock_guard g(wakeMutex_);
        port_ = port;
        wakeCallback_ = nullptr;
        wakeUser_ = nullptr;
    }
    {
        std::lock_guard g(eventsMutex_);
        events_.clear();  // queued for the previous consumer
        results_.clear();
    }
    consumer_ = port != 0;
    resync_ = true;
    wakePending_ = false;
    wake();
}

void Runtime::attachCallback(void (*cb)(void*), void* user) {
    {
        std::lock_guard g(wakeMutex_);
        port_ = 0;
        wakeCallback_ = cb;
        wakeUser_ = user;
    }
    {
        std::lock_guard g(eventsMutex_);
        events_.clear();  // queued for the previous consumer
        results_.clear();
    }
    consumer_ = cb != nullptr;
    resync_ = true;
    wakePending_ = false;
    wake();
}

void Runtime::requestResync() {
    resync_ = true;
    wake();
}

void Runtime::propChanged(PropBase& p) {
    Module& m = p.owner();
    if (!m.live() || resync_.load()) return;  // a pending resync sends everything anyway
    if (p.dirty_.exchange(true)) return;
    {
        std::lock_guard g(dirtyMutex_);
        if (!m.live()) {
            p.dirty_ = false;
            return;
        }
        dirtyProps_.push_back(&p);
    }
    wake();
}

void Runtime::metaChanged(PropBase& p) {
    Module& m = p.owner();
    if (!m.live() || resync_.load()) return;
    if (p.metaDirty_.exchange(true)) return;
    {
        std::lock_guard g(dirtyMutex_);
        if (!m.live()) {
            p.metaDirty_ = false;
            return;
        }
        dirtyMeta_.push_back(&p);
    }
    wake();
}

void Runtime::enqueueEvent(Rec kind, BuildFn build, const void* ctx) {
    // A pending resync sends the full state, which supersedes state records.
    // Signals are events without state, so they are kept for an attached consumer.
    if (resync_.load() && (kind != Rec::Signal || !consumer_.load())) return;
    bool overflow = false;
    {
        std::lock_guard g(eventsMutex_);
        const size_t start = events_.size();
        try {
            Writer w(events_);
            writeRecord(w, kind, [&](Writer& ww) { build(ww, ctx); });
        } catch (...) {
            events_.resize(start);  // never leave a partial record
            throw;
        }
        if (events_.size() > kMaxEventBytes) {
            events_.clear();
            events_.shrink_to_fit();
            overflow = true;
        }
    }
    if (overflow) {
        logf("change feed overflow (consumer not draining); the next drain is a full resync and queued signals are dropped");
        resync_ = true;
    }
    wake();
}

void Runtime::enqueueResult(uint32_t callId, int32_t status, const std::vector<uint8_t>& value, const std::string& error) {
    {
        std::lock_guard g(eventsMutex_);
        Writer w(results_);
        writeRecord(w, Rec::Result, [&](Writer& ww) {
            ww.u32(callId);
            ww.i32(status);
            if (status == NATIVEBIND_OK) ww.bytes(value.data(), value.size());
            else ww.str(error);
        });
    }
    wake();
}

void Runtime::encodeInstanceAdded(Writer& w, const Module& m) {
    writeRecord(w, Rec::InstanceAdded, [&](Writer& ww) {
        ww.u32(m.handle_);
        ww.u16(m.typeId_);
        ww.u64(m.key_);
    });
}

void Runtime::encodePropRecord(Writer& w, const PropBase& p) {
    writeRecord(w, Rec::Prop, [&](Writer& ww) {
        ww.u32(p.owner().handle());
        ww.u16(p.index());
        p.encodeState(ww);
    });
}

void Runtime::encodeMetaRecord(Writer& w, const PropBase& p) {
    writeRecord(w, Rec::Meta, [&](Writer& ww) {
        ww.u32(p.owner().handle());
        ww.u16(p.index());
        p.encodeMeta(ww);
    });
}

void Runtime::encodeFullState(Writer& w) {
    writeRecord(w, Rec::Resync, [](Writer&) {});
    for (uint32_t h : order_) {
        const Module* m = findLocked(h);
        if (!m || !m->live()) continue;
        encodeInstanceAdded(w, *m);
        for (const PropBase* p : m->props_) {
            encodeMetaRecord(w, *p);
            encodePropRecord(w, *p);
        }
        for (const ListBase* l : m->lists_)
            writeRecord(w, Rec::ListReset, [&](Writer& ww) { l->encodeReset(ww); });
    }
}

void Runtime::endBatch() {
    commit_.unlock_shared();
    if (drainDeferred_.exchange(false)) {
        wakePending_.store(false);  // the deferred drain may have left it set
        wake();
    }
}

namespace {
// Copies the Signal records of a queue of framed records (u8 kind, u32 length, payload).
void keepSignals(const std::vector<uint8_t>& records, std::vector<uint8_t>& out) {
    size_t at = 0;
    while (at + 5 <= records.size()) {
        uint32_t len;
        std::memcpy(&len, records.data() + at + 1, 4);
        const size_t end = at + 5 + len;
        if (records[at] == static_cast<uint8_t>(Rec::Signal))
            out.insert(out.end(), records.begin() + static_cast<std::ptrdiff_t>(at),
                       records.begin() + static_cast<std::ptrdiff_t>(end));
        at = end;
    }
}
}  // namespace

const std::vector<uint8_t>& Runtime::drain() {
    drainBuffer_.clear();
    // Never block the UI thread on a batch. If one is open, report nothing
    // now; endBatch wakes the consumer. Flag first, then retry, so a batch
    // that closes in between is not missed.
    std::unique_lock commit(commit_, std::try_to_lock);
    if (!commit.owns_lock()) {
        drainDeferred_.store(true);
        if (!commit.try_lock()) return drainBuffer_;
    }
    drainDeferred_.store(false);
    wakePending_.store(false);
    Writer w(drainBuffer_);
    std::shared_lock reg(registry_);
    if (resync_.exchange(false)) {
        std::vector<uint8_t> signals;
        {
            std::lock_guard g(eventsMutex_);
            keepSignals(events_, signals);
            events_.clear();
        }
        {
            std::lock_guard g(dirtyMutex_);
            for (PropBase* p : dirtyProps_) p->dirty_ = false;
            for (PropBase* p : dirtyMeta_) p->metaDirty_ = false;
            dirtyProps_.clear();
            dirtyMeta_.clear();
        }
        encodeFullState(w);
        drainBuffer_.insert(drainBuffer_.end(), signals.begin(), signals.end());
    } else {
        {
            std::lock_guard g(eventsMutex_);
            drainBuffer_.insert(drainBuffer_.end(), events_.begin(), events_.end());
            events_.clear();
        }
        std::vector<PropBase*> props, metas;
        {
            std::lock_guard g(dirtyMutex_);
            props.swap(dirtyProps_);
            metas.swap(dirtyMeta_);
        }
        for (PropBase* p : metas) {
            p->metaDirty_ = false;
            encodeMetaRecord(w, *p);
        }
        for (PropBase* p : props) {
            p->dirty_ = false;
            encodePropRecord(w, *p);
        }
    }
    {
        std::lock_guard g(eventsMutex_);
        drainBuffer_.insert(drainBuffer_.end(), results_.begin(), results_.end());
        results_.clear();
    }
    return drainBuffer_;
}

PropBase& Runtime::findProperty(std::string_view module, std::string_view prop, uint64_t key) {
    std::shared_lock reg(registry_);
    bool typeFound = false;
    for (uint32_t h : order_) {
        Module* m = findLocked(h);
        if (!m || !m->live() || module != m->type_->name) continue;
        typeFound = true;
        if (m->key_ != key) continue;
        for (PropBase* p : m->props_)
            if (prop == p->name()) return *p;
        throw std::logic_error("nativebind::property: " + std::string(module) + " has no property " + std::string(prop));
    }
    throw std::logic_error("nativebind::property: no " + std::string(module) +
                           (typeFound ? " with key " + std::to_string(key) : std::string(" module")) +
                           " (is it started, and is its .cpp in nativebind_add_modules?)");
}

// ------------------------------------------------------------------ UI operations

int32_t Runtime::write(uint32_t instance, uint16_t prop, const uint8_t* data, size_t len, uint32_t seq) {
    if (!started_) {
        setLastError("nativebind is not started");
        return NATIVEBIND_E_NOT_STARTED;
    }
    std::shared_lock reg(registry_);
    Module* m = findLocked(instance);
    if (!m || !m->live()) {
        setLastError("no instance " + std::to_string(instance));
        return NATIVEBIND_E_NO_INSTANCE;
    }
    if (prop >= m->props_.size()) {
        setLastError(std::string(m->type_->name) + " has no property #" + std::to_string(prop));
        return NATIVEBIND_E_NO_MEMBER;
    }
    PropBase& p = *m->props_[prop];
    if (!p.writable()) {
        setLastError(std::string(m->type_->name) + "." + p.name() + " is read-only");
        return NATIVEBIND_E_READ_ONLY;
    }
    Meta meta;
    bool enabled;
    {
        std::lock_guard g(p.mutex_);
        meta = p.meta_;
        enabled = p.enabled_;
    }
    if (!enabled) {
        setLastError(std::string(m->type_->name) + "." + p.name() + " is disabled");
        return NATIVEBIND_E_DISABLED;
    }
    const std::string denied = checkGuard({GuardRequest::Kind::Write, m->type_->name, p.name(), &meta, 0});
    if (!denied.empty()) {
        setLastError(std::string(m->type_->name) + "." + p.name() + ": " + denied);
        return NATIVEBIND_E_ACCESS;
    }
    try {
        Reader r(data, len);
        p.uiWrite(r, seq);
    } catch (const DecodeError& e) {
        setLastError(std::string(m->type_->name) + "." + p.name() + ": " + e.what());
        return NATIVEBIND_E_TYPE;
    }
    touch();
    return NATIVEBIND_OK;
}

int32_t Runtime::invoke(uint32_t instance, uint16_t method, const uint8_t* data, size_t len, uint32_t callId) {
    if (!started_) {
        setLastError("nativebind is not started");
        return NATIVEBIND_E_NOT_STARTED;
    }
    Module* m;
    {
        std::shared_lock reg(registry_);
        m = findLocked(instance);
        if (!m || !m->live()) {
            setLastError("no instance " + std::to_string(instance));
            return NATIVEBIND_E_NO_INSTANCE;
        }
        if (method >= m->type_->methodCount) {
            setLastError(std::string(m->type_->name) + " has no method #" + std::to_string(method));
            return NATIVEBIND_E_NO_MEMBER;
        }
    }
    std::vector<uint8_t> args(data, data + len);
    postFor(
        instance,
        [this, m, method, args = std::move(args), callId] {
            std::vector<uint8_t> out;
            Writer w(out);
            Reader r(args.data(), args.size());
            int32_t status = NATIVEBIND_OK;
            std::string error;
            try {
                m->type_->invoke(*m, method, r, w);
                if (out.empty()) w.tag(Tag::Void);
            } catch (const AccessDenied& e) {
                status = NATIVEBIND_E_ACCESS;
                error = e.what();
            } catch (const DecodeError& e) {
                status = NATIVEBIND_E_TYPE;
                error = e.what();
            } catch (const std::exception& e) {
                status = NATIVEBIND_E_EXCEPTION;
                error = e.what();
            } catch (...) {
                status = NATIVEBIND_E_EXCEPTION;
                error = "unknown exception";
            }
            enqueueResult(callId, status, out, error);
        },
        [this, callId] { enqueueResult(callId, NATIVEBIND_E_NO_INSTANCE, {}, "instance destroyed before the call ran"); });
    touch();
    return NATIVEBIND_OK;
}

void Runtime::setGuard(Guard g) {
    auto next = g ? std::make_shared<const Guard>(std::move(g)) : nullptr;
    std::lock_guard l(guardMutex_);
    guard_ = std::move(next);
}

bool Runtime::hasGuard() const {
    std::lock_guard l(guardMutex_);
    return guard_ != nullptr;
}

std::string Runtime::checkGuard(const GuardRequest& request) const {
    std::shared_ptr<const Guard> g;
    {
        std::lock_guard l(guardMutex_);
        g = guard_;
    }
    if (!g) return {};
    try {
        return (*g)(request);
    } catch (const std::exception& e) {
        return std::string("guard failed: ") + e.what();
    }
}

void Runtime::touch() noexcept {
    lastActivityNs_.store(std::chrono::duration_cast<std::chrono::nanoseconds>(
                              std::chrono::steady_clock::now().time_since_epoch())
                              .count());
}

std::chrono::steady_clock::time_point Runtime::lastActivity() const noexcept {
    return std::chrono::steady_clock::time_point(
        std::chrono::duration_cast<std::chrono::steady_clock::duration>(std::chrono::nanoseconds(lastActivityNs_.load())));
}

// ------------------------------------------------------------------ hooks used by headers

void enqueueEvent(Rec kind, BuildFn build, const void* ctx) { Runtime::get().enqueueEvent(kind, build, ctx); }
void propChanged(PropBase& p) { Runtime::get().propChanged(p); }
void metaChanged(PropBase& p) { Runtime::get().metaChanged(p); }
void postFor(uint32_t handle, std::function<void()> fn, std::function<void()> dropped) {
    Runtime::get().postFor(handle, std::move(fn), std::move(dropped));
}
uint32_t newHandle() noexcept { return gNextHandle.fetch_add(1) + 1; }
TimerId newTimerId() noexcept { return gNextTimer.fetch_add(1) + 1; }
void armTimer(Module& owner, TimerId id, std::chrono::milliseconds delay, std::chrono::milliseconds period,
              std::function<void()> fn) {
    Runtime::get().armTimer(owner, id, delay, period, std::move(fn));
}
void cancelTimer(TimerId id) { Runtime::get().cancelTimer(id); }
void moduleGone(uint32_t handle) noexcept {
    if (gRuntimeAlive.load()) Runtime::get().moduleGone(handle);
}

Module& adopt(const std::type_info& type, std::unique_ptr<Module> module, uint64_t key) {
    return Runtime::get().adopt(type, std::move(module), key);
}
Module& singleton(const std::type_info& type) { return Runtime::get().singleton(type); }
std::vector<Module*> instances(const std::type_info& type) { return Runtime::get().instances(type); }
void destroy(uint32_t handle) { Runtime::get().destroy(handle); }

}  // namespace detail

// ------------------------------------------------------------------ public API

void start() { detail::Runtime::get().start(); }
void stop() { detail::Runtime::get().stop(); }
bool started() noexcept { return detail::Runtime::get().started(); }
bool flush(std::chrono::milliseconds timeout) { return detail::Runtime::get().flush(timeout); }
void post(std::function<void()> fn) { detail::Runtime::get().loop().post(std::move(fn)); }
bool onNativeBindThread() noexcept { return detail::Runtime::get().loop().onThread(); }
void setLogHandler(LogHandler handler) noexcept { detail::gLogHandler.store(handler); }
void setGuard(Guard guard) { detail::Runtime::get().setGuard(std::move(guard)); }
std::chrono::steady_clock::time_point lastUiActivity() noexcept { return detail::Runtime::get().lastActivity(); }
void touchUiActivity() noexcept { detail::Runtime::get().touch(); }
void log(std::string_view message) { detail::logf("%.*s", static_cast<int>(message.size()), message.data()); }

namespace glue {

Registrar::Registrar(const ModuleType& type) { detail::Runtime::get().registerType(type); }

void requirePermission(const char* module, const char* method, int64_t permission) {
    auto& rt = detail::Runtime::get();
    if (!rt.hasGuard())
        throw AccessDenied(std::string(module) + "." + method + " needs permission " + std::to_string(permission) +
                           " but no nativebind::setGuard policy is installed");
    const std::string denied = rt.checkGuard({GuardRequest::Kind::Invoke, module, method, nullptr, permission});
    if (!denied.empty()) throw AccessDenied(denied);
}

void unknownMethod(const char* module, uint16_t method) {
    throw std::logic_error(std::string(module) + " has no method #" + std::to_string(method));
}

}  // namespace glue
}  // namespace nativebind
