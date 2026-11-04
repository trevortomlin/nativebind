#pragma once
// The runtime: module registry, change feed and nativebind thread.
//
// Lock order (outer to inner): lifecycle_ > registry_ > (list/prop mutex) >
// events_ / dirty_ / pendingTimers_ > loop. User callbacks never run with a
// runtime lock held.

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <shared_mutex>
#include <string>
#include <string_view>
#include <typeindex>
#include <unordered_map>
#include <vector>

#include "loop.hpp"
#include "nativebind/glue.hpp"
#include "nativebind/list.hpp"
#include "nativebind/module.hpp"
#include "nativebind/runtime.hpp"
#include "nativebind/property.hpp"
#include "nativebind/signal.hpp"

namespace nativebind::detail {

/// Per-thread message for the last failed C ABI call.
void setLastError(std::string message);
const char* lastError() noexcept;

class Runtime {
public:
    static Runtime& get();
    ~Runtime();

    // lifecycle
    void start();
    void stop();
    bool started() const noexcept { return started_.load(); }
    bool flush(std::chrono::milliseconds timeout);
    Loop& loop() noexcept { return loop_; }

    // types
    void registerType(const glue::ModuleType& type);
    int typeCount() const;
    int typeId(std::string_view name) const;
    const glue::ModuleType* type(int id) const;

    // instances
    Module& adopt(const std::type_info& type, std::unique_ptr<Module> module, uint64_t key);
    Module& singleton(const std::type_info& type);
    std::vector<Module*> instances(const std::type_info& type);
    void destroy(uint32_t handle);
    bool isLive(uint32_t handle) const;

    // consumer (Dart)
    void attachPort(int64_t port);
    void attachCallback(void (*wake)(void*), void* user);
    const std::vector<uint8_t>& drain();
    void requestResync();

    // UI operations; return a NATIVEBIND_* status
    int32_t write(uint32_t instance, uint16_t prop, const uint8_t* data, size_t len, uint32_t seq);
    int32_t invoke(uint32_t instance, uint16_t method, const uint8_t* data, size_t len, uint32_t callId);

    // hooks from members
    void propChanged(PropBase& p);
    void metaChanged(PropBase& p);
    void enqueueEvent(Rec kind, BuildFn build, const void* ctx);
    void postFor(uint32_t handle, std::function<void()> fn, std::function<void()> dropped);
    void armTimer(Module& owner, TimerId id, std::chrono::milliseconds delay, std::chrono::milliseconds period,
                  std::function<void()> fn);
    void cancelTimer(TimerId id);
    void moduleGone(uint32_t handle) noexcept;

    // batches (nativebind::Batch): the feed is not read while one is open.
    // drain() never waits for them; it returns nothing and the batch that
    // closes last wakes the consumer again.
    void beginBatch() { commit_.lock_shared(); }
    void endBatch();
    PropBase& findProperty(std::string_view module, std::string_view prop, uint64_t key);

    // access policy (nativebind::setGuard); copied out under guardMutex_
    void setGuard(Guard g);
    /// Empty if allowed, else the reason. Runs the guard without guardMutex_ held.
    std::string checkGuard(const GuardRequest& request) const;
    bool hasGuard() const;
    void touch() noexcept;
    std::chrono::steady_clock::time_point lastActivity() const noexcept;

private:
    Runtime() = default;

    struct PendingTimer {
        TimerId id;
        std::chrono::milliseconds delay, period;
        std::function<void()> fn;
    };

    void runSync(const std::function<void()>& fn);
    Module& registerLocked(const glue::ModuleType& type, std::unique_ptr<Module> module, uint64_t key);
    void destroyNow(uint32_t handle, bool callStop);
    void armPending(Module& m);
    void wake();
    void encodeFullState(Writer& w);
    void encodeInstanceAdded(Writer& w, const Module& m);
    void encodePropRecord(Writer& w, const PropBase& p);
    void encodeMetaRecord(Writer& w, const PropBase& p);
    Module* findLocked(uint32_t handle) const;
    const glue::ModuleType* typeFor(const std::type_info& t) const;
    void enqueueResult(uint32_t callId, int32_t status, const std::vector<uint8_t>& value, const std::string& error);

    // lifecycle
    std::mutex lifecycle_;
    std::atomic<bool> started_{false};
    bool stopping_ = false;  // guarded by registry_: stop() took its snapshot of modules
    Loop loop_;

    // types (registered during static initialization)
    mutable std::mutex typesMutex_;
    std::vector<const glue::ModuleType*> types_;
    std::unordered_map<std::type_index, uint16_t> typeIndex_;

    // Shared by open batches, exclusive while the feed is read (lock order:
    // commit_ > registry_).
    std::shared_mutex commit_;
    /// A drain found a batch open; the next endBatch wakes the consumer.
    std::atomic<bool> drainDeferred_{false};

    // instances
    mutable std::shared_mutex registry_;
    std::unordered_map<uint32_t, std::unique_ptr<Module>> instances_;
    std::vector<uint32_t> order_;  // creation order

    // change feed
    std::mutex dirtyMutex_;
    std::vector<PropBase*> dirtyProps_, dirtyMeta_;
    std::mutex eventsMutex_;
    std::vector<uint8_t> events_, results_;
    std::atomic<bool> resync_{true};
    std::atomic<bool> wakePending_{false};
    std::vector<uint8_t> drainBuffer_;

    std::mutex wakeMutex_;
    std::atomic<bool> consumer_{false};  // a port or callback is attached
    int64_t port_ = 0;
    void (*wakeCallback_)(void*) = nullptr;
    void* wakeUser_ = nullptr;

    // timers of modules that are not live yet
    std::mutex pendingMutex_;
    std::unordered_map<uint32_t, std::vector<PendingTimer>> pendingTimers_;

    mutable std::mutex guardMutex_;
    std::shared_ptr<const Guard> guard_;
    std::atomic<int64_t> lastActivityNs_{0};
};

}  // namespace nativebind::detail
