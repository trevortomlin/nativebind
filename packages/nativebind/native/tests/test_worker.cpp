#include <atomic>
#include <chrono>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "feed.hpp"
#include "harness.hpp"
#include "modules/device.cpp"  // class definitions only (all inline), safe to include
#include "modules/thermo.cpp"  // class definitions only (all inline), safe to include

using namespace nativebind;
using namespace std::chrono_literals;

namespace {

bool waitFor(const std::function<bool()>& cond, std::chrono::milliseconds timeout = 3s) {
    const auto end = std::chrono::steady_clock::now() + timeout;
    while (std::chrono::steady_clock::now() < end) {
        if (cond()) return true;
        std::this_thread::sleep_for(1ms);
    }
    return cond();
}

}  // namespace

TEST(worker_runs_tasks_in_order_on_its_thread) {
    Worker w("test-worker");
    std::vector<int> seen;
    std::atomic<bool> allOnThread{true};
    for (int i = 0; i < 100; ++i)
        w.post([&, i] {
            if (!w.onThread()) allOnThread = false;
            seen.push_back(i);
        });
    std::atomic<bool> done{false};
    w.post([&] { done = true; });
    CHECK(waitFor([&] { return done.load(); }));
    CHECK(allOnThread.load());
    CHECK_EQ(seen.size(), size_t{100});
    for (int i = 0; i < 100; ++i) CHECK_EQ(seen[static_cast<size_t>(i)], i);
    CHECK(!w.onThread());
}

TEST(worker_periodic_jobs_and_cancel) {
    Worker w;
    std::atomic<int> fast{0}, cancelled{0};
    w.every(2ms, [&] { ++fast; }, true);
    const auto id = w.every(1ms, [&] { ++cancelled; });
    w.cancel(id);
    CHECK(waitFor([&] { return fast.load() >= 5; }));
    w.stop();
    const int after = fast.load();
    std::this_thread::sleep_for(10ms);
    CHECK_EQ(fast.load(), after);  // nothing runs after stop
    CHECK(cancelled.load() <= 1);
}

TEST(worker_survives_exceptions_and_stops_long_loops) {
    setLogHandler([](const char*) {});
    Worker w;
    std::atomic<bool> after{false};
    w.post([] { throw std::runtime_error("bus error"); });
    w.post([&] { after = true; });
    CHECK(waitFor([&] { return after.load(); }));
    setLogHandler(nullptr);

    std::atomic<bool> exited{false};
    w.post([&] {
        while (w.sleepFor(1h)) {
        }
        exited = true;  // sleepFor returned false because of stop()
    });
    std::this_thread::sleep_for(5ms);
    const auto t0 = std::chrono::steady_clock::now();
    w.stop();
    CHECK(exited.load());
    CHECK(std::chrono::steady_clock::now() - t0 < 1s);
    w.stop();  // idempotent
}

TEST(cancelling_the_job_a_worker_waits_for_is_safe) {
    Worker w;
    const auto id = w.every(std::chrono::seconds(10), [] {});
    std::this_thread::sleep_for(20ms);  // the worker now waits until that job is due
    w.cancel(id);                       // frees the job...
    std::atomic<bool> ran{false};
    w.post([&] { ran = true; });  // ...and wakes the worker, which must not read it
    CHECK(waitFor([&] { return ran.load(); }));
}

TEST(a_stopped_worker_ignores_work_until_started_again) {
    Worker w;
    std::atomic<int> n{0};
    w.post([&] { ++n; });  // the first post starts it
    CHECK(waitFor([&] { return n.load() == 1; }));
    w.stop();  // e.g. in onStop, after closing the port the worker reads
    w.post([&] { ++n; });  // a late post from another thread...
    w.every(1ms, [&] { ++n; });
    std::this_thread::sleep_for(30ms);
    CHECK_EQ(n.load(), 1);  // ...must not bring I/O back on closed resources
    CHECK(!w.running());
    w.start();  // an explicit start resumes it
    w.post([&] { ++n; });
    CHECK(waitFor([&] { return n.load() == 2; }));
}

TEST(a_worker_owned_by_a_module_stops_after_its_onStop) {
    feed::Started s;
    Zone& z = spawn<Zone>(21, "owner");
    auto w = std::make_unique<Worker>(z, "owned");
    std::atomic<int> ticks{0};
    w->every(1ms, [&] { ++ticks; });
    CHECK(waitFor([&] { return ticks.load() > 0; }));
    bool runningInOnStop = false;
    Zone::stopHook = [&] { runningInOnStop = w->running(); };
    destroy(z);
    CHECK(flush());
    Zone::stopHook = nullptr;
    CHECK(runningInOnStop);  // onStop may still use it...
    CHECK(!w->running());    // ...and it is stopped before the module is deleted
    // A late post must not bring it back for a module that is gone.
    std::atomic<bool> ran{false};
    w->post([&] { ran = true; });
    std::this_thread::sleep_for(20ms);
    CHECK(!ran.load());
    CHECK(!w->running());
    w.reset();  // outliving its owner is fine
}

TEST(a_worker_destroyed_before_its_owner_is_forgotten) {
    feed::Started s;
    Zone& z = spawn<Zone>(22, "owner");
    {
        Worker w(z, "short-lived");
        w.post([] {});
    }
    destroy(z);  // must not touch the destroyed worker
    CHECK(flush());
}

TEST(ui_writes_are_forwarded_to_the_io_thread) {
    feed::Started s;
    feed::Consumer c;
    c.pump();
    auto& dev = singleton<Device>();
    auto v = feed::encode(42.0);
    CHECK_EQ(nativebind_write(dev.handle(), 3, v.data(), static_cast<uint32_t>(v.size()), 1), NATIVEBIND_OK);
    CHECK(waitFor([&] { return dev.written.get() == 42.0; }));
}

TEST(batches_are_never_seen_half_applied) {
    feed::Started s;
    feed::Consumer c;
    c.pump();
    auto& dev = singleton<Device>();
    CHECK_EQ(nativebind_invoke(dev.handle(), 0, nullptr, 0, 1), NATIVEBIND_OK);  // startPolling
    int checked = 0;
    const auto end = std::chrono::steady_clock::now() + 300ms;
    while (std::chrono::steady_clock::now() < end) {
        c.pump();
        const auto* inst = c.mirror.find(dev.handle());
        CHECK(inst != nullptr);
        const auto& a = inst->props.at(0).value;
        const auto& b = inst->props.at(1).value;
        CHECK_EQ(a.i + b.i, int64_t{100});
        ++checked;
    }
    CHECK(checked > 10);
    CHECK(dev.polls.get() > 10);
}

TEST(nested_batches_and_batches_without_a_consumer) {
    feed::Started s;
    auto& th = singleton<Thermo>();
    {
        Batch outer;
        {
            Batch inner;
            th.roomTemp = 1.0;
        }
        th.roomTemp = 2.0;
    }
    nativebind::batch([&] { th.roomTemp = 3.0; });
    feed::Consumer c;
    c.pump();  // would deadlock if a batch leaked its lock
    CHECK_EQ(c.mirror.find(th.handle())->props.at(4).value.d, 3.0);
}

TEST(drain_does_not_wait_for_open_batches) {
    feed::Started s;
    feed::Consumer c;
    c.pump();
    auto& dev = singleton<Device>();
    std::atomic<bool> inBatch{false}, release{false};
    std::thread worker([&] {
        Batch b;
        dev.a = 7;
        dev.b = 93;
        inBatch = true;
        const auto until = std::chrono::steady_clock::now() + 500ms;  // never hang the suite
        while (!release && std::chrono::steady_clock::now() < until) std::this_thread::sleep_for(1ms);
    });
    CHECK(waitFor([&] { return inBatch.load(); }));

    // The UI thread drains here: it must not block until the batch closes.
    const auto t0 = std::chrono::steady_clock::now();
    auto recs = c.pump();
    const auto waited = std::chrono::steady_clock::now() - t0;
    const int wakesBefore = c.wakes();
    release = true;
    worker.join();
    CHECK(waited < 100ms);
    CHECK(feed::only(recs, feed::Rec::Prop).empty());  // nothing half-applied

    // Closing the batch wakes the consumer, and the next drain has all of it.
    CHECK(waitFor([&] { return c.wakes() > wakesBefore; }));
    c.pump();
    const auto* st = c.mirror.find(dev.handle());
    CHECK_EQ(st->props.at(0).value.i, int64_t{7});
    CHECK_EQ(st->props.at(1).value.i, int64_t{93});
}

TEST(property_lookup_by_name) {
    feed::Started s;
    auto& sp = nativebind::property<double>("Thermo", "setpoint");
    CHECK(&sp == &singleton<Thermo>().setpoint);
    CHECK_THROWS(nativebind::property<int32_t>("Thermo", "setpoint"), std::logic_error);  // wrong type
    CHECK_THROWS(nativebind::property<double>("Thermo", "nope"), std::logic_error);
    CHECK_THROWS(nativebind::property<double>("Nope", "setpoint"), std::logic_error);

    spawn<Zone>(7, "Lab");
    CHECK_EQ(nativebind::property<std::string>("Zone", "label", 7).get(), std::string("Lab"));
    CHECK_THROWS(nativebind::property<std::string>("Zone", "label", 8), std::logic_error);
}

TEST(stopping_the_runtime_stops_polling_workers) {
    int stops = 0;
    {
        feed::Started s;
        auto& dev = singleton<Device>();
        CHECK_EQ(nativebind_invoke(dev.handle(), 0, nullptr, 0, 1), NATIVEBIND_OK);
        CHECK(waitFor([&] { return dev.polls.get() > 5; }));
        stops = dev.onStopCalls.load();
    }
    CHECK_EQ(stops, 0);  // checked before stop; ASan/TSan verify the shutdown itself
}

TEST(stress_workers_batches_and_writes_together) {
    feed::Started s;
    feed::Consumer c;
    c.pump();
    auto& dev = singleton<Device>();
    auto& th = singleton<Thermo>();
    nativebind_invoke(dev.handle(), 0, nullptr, 0, 1);
    std::atomic<bool> done{false};
    std::thread consumer([&] {
        while (!done) {
            c.pump();
            const auto* inst = c.mirror.find(dev.handle());
            if (inst && inst->props.count(0) && inst->props.count(1)) {
                if (inst->props.at(0).value.i + inst->props.at(1).value.i != 100) std::abort();
            }
        }
    });
    std::vector<std::thread> writers;
    for (int t = 0; t < 3; ++t)
        writers.emplace_back([&, t] {
            Worker w("writer-" + std::to_string(t));
            std::atomic<int> left{500};
            for (int i = 0; i < 500; ++i)
                w.post([&, i] {
                    nativebind::batch([&] { th.roomTemp = i; });
                    auto v = feed::encode(static_cast<double>(i % 90));
                    nativebind_write(dev.handle(), 3, v.data(), static_cast<uint32_t>(v.size()), static_cast<uint32_t>(i));
                    --left;
                });
            while (left > 0) std::this_thread::sleep_for(1ms);
        });
    for (auto& w : writers) w.join();
    done = true;
    consumer.join();
    c.settle();
    CHECK_EQ(c.mirror.gaps, 0);
}
