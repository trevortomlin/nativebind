#include "loop.hpp"

#include <exception>
#include <stdexcept>

#include "nativebind/detail/core.hpp"

namespace nativebind::detail {

void runGuarded(const std::function<void()>& fn, const char* what) noexcept {
    try {
        fn();
    } catch (const std::exception& e) {
        logf("%s threw: %s", what, e.what());
    } catch (...) {
        logf("%s threw a non-std exception", what);
    }
}

Loop::~Loop() { stop(); }

void Loop::start() {
    std::lock_guard g(mutex_);
    if (running_) return;
    running_ = true;
    stopping_ = false;
    thread_ = std::thread([this] {
        threadId_.store(std::this_thread::get_id());
        run();
    });
}

void Loop::stop() {
    {
        std::lock_guard g(mutex_);
        if (!running_) return;
        if (onThread()) throw std::logic_error("nativebind: stop() called on the nativebind thread");
        stopping_ = true;
    }
    cv_.notify_all();
    thread_.join();
    std::lock_guard g(mutex_);
    threadId_.store(std::thread::id{});
    tasks_.clear();
    timers_.clear();
    running_ = false;
    stopping_ = false;
}

bool Loop::running() const {
    std::lock_guard g(mutex_);
    return running_;
}

void Loop::post(Task task) {
    {
        std::lock_guard g(mutex_);
        tasks_.push_back(std::move(task));
    }
    cv_.notify_one();
}

void Loop::addTimer(uint64_t id, uint32_t owner, std::chrono::milliseconds delay, std::chrono::milliseconds period,
                    Task fn) {
    {
        std::lock_guard g(mutex_);
        timers_[id] = Timer{owner, Clock::now() + delay, period, std::make_shared<Task>(std::move(fn))};
    }
    cv_.notify_one();
}

void Loop::cancel(uint64_t id) {
    std::lock_guard g(mutex_);
    timers_.erase(id);
}

void Loop::cancelOwner(uint32_t owner) {
    std::lock_guard g(mutex_);
    std::erase_if(timers_, [owner](const auto& entry) { return entry.second.owner == owner; });
}

void Loop::run() {
    std::unique_lock lk(mutex_);
    while (!stopping_) {
        if (!tasks_.empty()) {
            Task task = std::move(tasks_.front());
            tasks_.pop_front();
            lk.unlock();
            runGuarded(task, "nativebind task");
            lk.lock();
            continue;
        }
        const auto now = Clock::now();
        uint64_t next = 0;
        Clock::time_point due = Clock::time_point::max();
        for (const auto& [id, t] : timers_)
            if (t.due < due) {
                due = t.due;
                next = id;
            }
        if (next != 0 && due <= now) {
            auto it = timers_.find(next);
            std::shared_ptr<Task> fn = it->second.fn;
            if (it->second.period.count() > 0) {
                it->second.due += it->second.period;
                if (it->second.due <= now) it->second.due = now + it->second.period;  // no catch-up bursts
            } else {
                timers_.erase(it);
            }
            lk.unlock();
            runGuarded(*fn, "nativebind timer");
            lk.lock();
            continue;
        }
        if (next != 0) cv_.wait_until(lk, due);
        else cv_.wait(lk);
    }
}

}  // namespace nativebind::detail
