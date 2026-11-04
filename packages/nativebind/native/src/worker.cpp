#include "nativebind/worker.hpp"

#include <exception>
#include <stdexcept>

#if defined(__linux__)
#include <pthread.h>
#endif

#include "runtime.hpp"

namespace nativebind {

Worker::Worker(std::string name) : name_(std::move(name)) {}

Worker::Worker(Module& owner, std::string name) : name_(std::move(name)), owner_(&owner) {
    ownerEnd_ = owner.atEnd([this] {
        {
            std::lock_guard g(mutex_);
            ended_ = true;
            owner_ = nullptr;
        }
        try {
            stop();
        } catch (const std::exception& e) {
            detail::logf("worker %s: %s", name_.c_str(), e.what());
        }
    });
}

Worker::~Worker() {
    Module* owner;
    {
        std::lock_guard g(mutex_);
        owner = owner_;
    }
    if (owner) owner->cancelAtEnd(ownerEnd_);  // waits if the owner is stopping us right now
    try {
        stop();
    } catch (...) {
    }
}

void Worker::start() {
    std::lock_guard g(mutex_);
    stopped_ = false;  // explicitly resumed
    startLocked();
}

void Worker::startIfIdle() {
    std::lock_guard g(mutex_);
    if (!stopped_) startLocked();
}

void Worker::startLocked() {
    if (running_ || ended_) return;
    running_ = true;
    stopping_ = false;
    thread_ = std::thread([this] {
        threadId_.store(std::this_thread::get_id());
#if defined(__linux__)
        pthread_setname_np(pthread_self(), name_.substr(0, 15).c_str());
#endif
        run();
    });
}

void Worker::stop() {
    {
        std::lock_guard g(mutex_);
        stopped_ = true;  // later post/every are dropped until start()
        if (!running_) return;
        if (onThread()) throw std::logic_error("nativebind::Worker::stop() called on the worker itself");
        stopping_ = true;
    }
    cv_.notify_all();
    thread_.join();
    std::lock_guard g(mutex_);
    tasks_.clear();
    periodic_.clear();
    threadId_.store(std::thread::id{});
    running_ = false;
}

bool Worker::running() const {
    std::lock_guard g(mutex_);
    return running_;
}

bool Worker::onThread() const noexcept { return std::this_thread::get_id() == threadId_.load(); }

void Worker::post(std::function<void()> task) {
    startIfIdle();
    {
        std::lock_guard g(mutex_);
        if (stopping_ || !running_) return;
        tasks_.push_back(std::move(task));
    }
    cv_.notify_one();
}

uint64_t Worker::every(std::chrono::milliseconds period, std::function<void()> task, bool runNow) {
    if (period.count() <= 0) throw std::invalid_argument("nativebind::Worker::every: period must be positive");
    startIfIdle();
    uint64_t id;
    {
        std::lock_guard g(mutex_);
        id = nextId_++;
        if (!running_) return id;  // stopped, or the owner ended: never runs
        periodic_[id] = Periodic{Clock::now() + (runNow ? std::chrono::milliseconds(0) : period), period,
                                 std::make_shared<std::function<void()>>(std::move(task))};
    }
    cv_.notify_one();
    return id;
}

void Worker::cancel(uint64_t id) {
    std::lock_guard g(mutex_);
    periodic_.erase(id);
}

bool Worker::sleepFor(std::chrono::milliseconds d) {
    std::unique_lock lk(mutex_);
    cv_.wait_for(lk, d, [this] { return stopping_.load(); });
    return !stopping_;
}

void Worker::run() {
    std::unique_lock lk(mutex_);
    while (!stopping_) {
        if (!tasks_.empty()) {
            auto task = std::move(tasks_.front());
            tasks_.pop_front();
            lk.unlock();
            detail::runGuarded(task, name_.c_str());
            lk.lock();
            continue;
        }
        const auto now = Clock::now();
        auto next = periodic_.end();
        for (auto it = periodic_.begin(); it != periodic_.end(); ++it)
            if (next == periodic_.end() || it->second.due < next->second.due) next = it;
        if (next != periodic_.end() && next->second.due <= now) {
            auto task = next->second.task;
            next->second.due += next->second.period;
            if (next->second.due <= now) next->second.due = now + next->second.period;  // no catch-up bursts
            lk.unlock();
            detail::runGuarded(*task, name_.c_str());
            lk.lock();
            continue;
        }
        if (next != periodic_.end()) {
            // A copy: the wait releases the lock, and cancel() may free the job.
            const Clock::time_point due = next->second.due;
            cv_.wait_until(lk, due);
        } else {
            cv_.wait(lk);
        }
    }
}

// ------------------------------------------------------------------ Batch

namespace {
thread_local int tlsBatchDepth = 0;
}

Batch::Batch() {
    if (tlsBatchDepth++ == 0) detail::Runtime::get().beginBatch();
}

Batch::~Batch() {
    if (--tlsBatchDepth == 0) detail::Runtime::get().endBatch();
}

// ------------------------------------------------------------------ lookup

namespace detail {

PropBase& findProperty(std::string_view module, std::string_view prop, uint64_t key) {
    return Runtime::get().findProperty(module, prop, key);
}

}  // namespace detail
}  // namespace nativebind
