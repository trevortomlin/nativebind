// nativebind_bench: micro-benchmarks of the runtime's hot paths.
//
//   nativebind_bench            print results
//   nativebind_bench --check    also fail (exit 1) if a result exceeds its budget
//
// Budgets are ~10x the results of a Release build on a desktop x86-64 CPU;
// a Cortex-A53 (i.MX8M Mini) is roughly 6-8x slower per core, so the budgets
// also describe what the target can sustain.

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <functional>
#include <mutex>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include "feed.hpp"
#include "modules/device.cpp"  // class definitions only (all inline)
#include "modules/thermo.cpp"  // class definitions only (all inline)

using namespace nativebind;
using Clock = std::chrono::steady_clock;

namespace {

struct Result {
    std::string name;
    double value;
    const char* unit;
    double budget;
};

std::vector<Result> results;

/// Median over [rounds] of the per-iteration time of [fn] (called [iters] times per round).
double measure(int iters, const std::function<void()>& fn, int rounds = 7) {
    std::vector<double> per;
    for (int r = 0; r < rounds; ++r) {
        const auto t0 = Clock::now();
        for (int i = 0; i < iters; ++i) fn();
        per.push_back(std::chrono::duration<double, std::nano>(Clock::now() - t0).count() / iters);
    }
    std::sort(per.begin(), per.end());
    return per[per.size() / 2];
}

void report(const std::string& name, double ns, const char* unit, double budget) {
    double v = ns;
    if (std::strcmp(unit, "us") == 0) v = ns / 1000.0;
    results.push_back({name, v, unit, budget});
}

/// Wakes from the runtime, for latency measurements.
struct Waker {
    std::mutex m;
    std::condition_variable cv;
    int wakes = 0;
    static void onWake(void* self) {
        auto* w = static_cast<Waker*>(self);
        {
            std::lock_guard g(w->m);
            ++w->wakes;
        }
        w->cv.notify_one();
    }
    void attach() { nativebind_attach_callback(&Waker::onWake, this); }
    /// Drains until [pred] matches a record; returns false on timeout.
    bool waitFor(const std::function<bool(const feed::Record&)>& pred) {
        const auto end = Clock::now() + std::chrono::seconds(2);
        while (Clock::now() < end) {
            uint32_t len = 0;
            const uint8_t* p = nativebind_drain(&len);
            for (const auto& r : feed::decode(p, len))
                if (pred(r)) return true;
            std::unique_lock lk(m);
            const int seen = wakes;
            cv.wait_until(lk, end, [&] { return wakes != seen; });
        }
        return false;
    }
};

}  // namespace

int main(int argc, char** argv) {
    const bool check = argc > 1 && std::strcmp(argv[1], "--check") == 0;
    setLogHandler([](const char*) {});
    nativebind::start();
    Waker waker;
    waker.attach();
    uint32_t len = 0;
    nativebind_drain(&len);
    auto& th = singleton<Thermo>();

    // ---- property writes from C++ (the field bus path)
    {
        int i = 0;
        report("prop set (value changes)", measure(200000, [&] { th.roomTemp = static_cast<double>(++i); }), "ns", 300);
        report("prop set (unchanged)", measure(200000, [&] { th.roomTemp = 1.0; }), "ns", 150);
        nativebind_drain(&len);
    }
    {
        constexpr int threads = 4, per = 100000;
        std::vector<double> ns;
        for (int round = 0; round < 5; ++round) {
            std::atomic<bool> go{false};
            std::vector<std::thread> ts;
            for (int t = 0; t < threads; ++t)
                ts.emplace_back([&, t] {
                    while (!go) std::this_thread::yield();
                    for (int i = 0; i < per; ++i) th.roomTemp = static_cast<double>(i * threads + t);
                });
            const auto t0 = Clock::now();
            go = true;
            for (auto& t : ts) t.join();
            ns.push_back(std::chrono::duration<double, std::nano>(Clock::now() - t0).count() / (threads * per));
        }
        std::sort(ns.begin(), ns.end());
        report("prop set, 4 threads contending (per set)", ns[2], "ns", 1000);
        nativebind_drain(&len);
    }
    {
        int i = 0;
        report("Batch (empty)", measure(200000, [] { Batch b; }), "ns", 300);
        report("Batch of 3 sets", measure(100000, [&] {
                   Batch b;
                   th.roomTemp = static_cast<double>(++i);
                   th.stage = static_cast<Stage>(i % 3);
                   th.name = (i % 2) ? "a" : "b";
               }),
               "ns", 1000);
        report("signal emit (with consumer)", measure(100000, [&] { th.overTemp(1.0); }), "ns", 500);
        nativebind_drain(&len);
    }

    // ---- draining (the cost on the Dart/UI thread)
    {
        for (int k = 0; k < 300; ++k) spawn<Zone>(static_cast<uint64_t>(1000 + k), "zone " + std::to_string(k));
        nativebind_flush(5000);
        nativebind_drain(&len);
        auto zones = instances<Zone>();
        int v = 0;
        report("drain 900 dirty props (300 instances)", measure(20, [&] {
                   ++v;
                   for (Zone* z : zones) {
                       z->temp = static_cast<double>(v);
                       z->ticks = v;
                       z->label = "z" + std::to_string(v % 7);
                   }
                   nativebind_drain(&len);
               }),
               "us", 1000);
        report("drain, nothing pending", measure(20000, [&] { nativebind_drain(&len); }), "ns", 1000);
    }
    {
        auto& list = th.readings;
        report("2000 list inserts + drain", measure(10, [&] {
                   list.clear();
                   for (int i = 0; i < 2000; ++i) list.push_back(Reading{"sensor", static_cast<double>(i), {1, 2}});
                   nativebind_drain(&len);
               }),
               "us", 4000);
        std::vector<Reading> items;
        for (int i = 0; i < 500; ++i) items.push_back({"k" + std::to_string(i), static_cast<double>(i), {}});
        list.assign(items);
        nativebind_drain(&len);
        std::mt19937 rng(1);
        report("List::sync 500 shuffled", measure(20, [&] {
                   std::shuffle(items.begin(), items.end(), rng);
                   list.sync(items, [](const Reading& r) { return r.sensor; });
               }),
               "us", 3000);
        std::vector<Reading> rows;
        for (int i = 0; i < 5000; ++i) rows.push_back({"sensor-" + std::to_string(i), static_cast<double>(i), {}});
        list.assign(rows);
        nativebind_drain(&len);
        report("List::sync 5000 shuffled", measure(5, [&] {
                   std::shuffle(rows.begin(), rows.end(), rng);
                   list.sync(rows, [](const Reading& r) { return r.sensor; });
                   nativebind_drain(&len);
               }, 3),
               "us", 35000);
        list.clear();
        nativebind_drain(&len);
    }

    // ---- codec
    {
        const Reading r{"floor sensor", 21.5, {1, 2, 3, 4}};
        std::vector<uint8_t> buf;
        report("encode struct", measure(200000, [&] {
                   buf.clear();
                   Writer w(buf);
                   w.value(r);
               }),
               "ns", 700);
        report("decode struct", measure(200000, [&] {
                   Reader rd(buf.data(), buf.size());
                   (void)rd.value<Reading>();
               }),
               "ns", 700);
        const std::vector<Reading> many(1000, r);
        report("encode list of 1000 structs", measure(2000, [&] {
                   buf.clear();
                   Writer w(buf);
                   w.value(many);
               }),
               "us", 400);
        constexpr int threads = 4, per = 200000;
        std::vector<double> ns;
        for (int round = 0; round < 5; ++round) {
            std::atomic<bool> go{false};
            std::vector<std::thread> ts;
            for (int t = 0; t < threads; ++t)
                ts.emplace_back([&] {
                    std::vector<uint8_t> local;
                    while (!go) std::this_thread::yield();
                    for (int i = 0; i < per; ++i) {
                        local.clear();
                        Writer w(local);
                        w.value(r);
                    }
                });
            const auto t0 = Clock::now();
            go = true;
            for (auto& t : ts) t.join();
            ns.push_back(std::chrono::duration<double, std::nano>(Clock::now() - t0).count() / per);
        }
        std::sort(ns.begin(), ns.end());
        report("encode struct, 4 threads at once (per encode)", ns[2], "ns", 500);
    }

    // ---- the UI thread's share of a write: the nativebind_write call itself
    {
        Meta m = th.setpoint.meta();
        m.label = "Living room setpoint";
        m.attrs = {{"unit", "degrees Celsius"}, {"decimals", 1}, {"confirm", false}, {"hint", "Comfort temperature"}};
        th.setpoint.setMeta(m);
        nativebind_flush(5000);
        nativebind_drain(&len);
        const auto v = feed::encode(21.0);
        uint32_t seq = 0;
        report("nativebind_write call (4 attributes, no guard)", measure(20000, [&] {
                   nativebind_write(th.handle(), 0, v.data(), static_cast<uint32_t>(v.size()), ++seq);
               }),
               "ns", 3000);
        nativebind_flush(5000);
        nativebind_drain(&len);
    }

    // ---- round trips through the C ABI (what a touch costs end to end, minus Flutter)
    {
        uint32_t seq = 0;
        auto v = feed::encode(22.0);
        report("UI write -> acknowledged", measure(300, [&] {
                   const uint32_t s = ++seq;
                   v = feed::encode(15.0 + (s % 20) * 0.5);
                   nativebind_write(th.handle(), 0, v.data(), static_cast<uint32_t>(v.size()), s);
                   waker.waitFor([&](const feed::Record& r) { return r.kind == feed::Rec::Prop && r.member == 0 && r.seq == s; });
               }, 5),
               "us", 300);
        uint32_t call = 0;
        const auto args = feed::encode(1.5, 2.25);
        report("invoke -> result", measure(300, [&] {
                   const uint32_t id = ++call;
                   nativebind_invoke(th.handle(), 1, args.data(), static_cast<uint32_t>(args.size()), id);
                   waker.waitFor([&](const feed::Record& r) { return r.kind == feed::Rec::Result && r.callId == id; });
               }, 5),
               "us", 300);
    }
    {
        Worker w("bench");
        std::mutex m;
        std::condition_variable cv;
        bool done = false;
        report("Worker post -> run", measure(2000, [&] {
                   {
                       std::lock_guard g(m);
                       done = false;
                   }
                   w.post([&] {
                       {
                           std::lock_guard g(m);
                           done = true;
                       }
                       cv.notify_one();
                   });
                   std::unique_lock lk(m);
                   cv.wait(lk, [&] { return done; });
               }, 5),
               "us", 200);
    }

    nativebind_attach_callback(nullptr, nullptr);
    nativebind::stop();

    int failures = 0;
    std::printf("%-44s %12s %10s\n", "benchmark", "result", "budget");
    for (const auto& r : results) {
        const bool over = r.value > r.budget;
        if (over) ++failures;
        std::printf("%-44s %9.1f %-2s %7.0f %-2s%s\n", r.name.c_str(), r.value, r.unit, r.budget, r.unit,
                    over ? "  OVER BUDGET" : "");
    }
    if (check && failures > 0) {
        std::printf("\n%d benchmark(s) over budget\n", failures);
        return 1;
    }
    return 0;
}
