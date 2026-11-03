#pragma once
// The nativebind thread: a task queue plus timers.

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>

namespace nativebind::detail {

class Loop {
public:
    using Clock = std::chrono::steady_clock;
    using Task = std::function<void()>;

    ~Loop();

    void start();
    /// Stops and joins the thread; queued tasks and timers are discarded.
    void stop();
    bool running() const;
    bool onThread() const noexcept { return std::this_thread::get_id() == threadId_.load(); }

    void post(Task task);
    /// period == 0: one-shot.
    void addTimer(uint64_t id, uint32_t owner, std::chrono::milliseconds delay, std::chrono::milliseconds period,
                  Task fn);
    void cancel(uint64_t id);
    void cancelOwner(uint32_t owner);

private:
    struct Timer {
        uint32_t owner;
        Clock::time_point due;
        std::chrono::milliseconds period;
        std::shared_ptr<Task> fn;
    };

    void run();

    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::deque<Task> tasks_;
    std::unordered_map<uint64_t, Timer> timers_;
    std::thread thread_;
    std::atomic<std::thread::id> threadId_{};
    bool stopping_ = false;
    bool running_ = false;
};

/// Runs fn, logging instead of propagating exceptions.
void runGuarded(const std::function<void()>& fn, const char* what) noexcept;

}  // namespace nativebind::detail
