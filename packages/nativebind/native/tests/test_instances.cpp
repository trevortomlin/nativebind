#include <chrono>
#include <string>
#include <thread>

#include "feed.hpp"
#include "harness.hpp"
#include "modules/thermo.cpp"  // class definitions only (all inline), safe to include

using namespace nativebind;
using namespace std::chrono_literals;
using feed::Rec;

namespace {

bool waitFor(const std::function<bool()>& cond, std::chrono::milliseconds timeout = 2s) {
    const auto end = std::chrono::steady_clock::now() + timeout;
    while (std::chrono::steady_clock::now() < end) {
        if (cond()) return true;
        std::this_thread::sleep_for(2ms);
    }
    return cond();
}

}  // namespace

TEST(spawn_and_destroy_instances) {
    feed::Started s;
    feed::Consumer c;
    c.pump();

    Zone& z1 = spawn<Zone>(1, "Kitchen");
    Zone& z2 = spawn<Zone>(2, "Office");
    auto recs = c.settle();
    const auto added = feed::only(recs, Rec::InstanceAdded);
    CHECK_EQ(added.size(), size_t{2});
    CHECK_EQ(added[0].key, uint64_t{1});
    CHECK_EQ(static_cast<int>(added[0].type), nativebind_type_id("Zone"));
    CHECK(z1.started && z2.started);
    CHECK_EQ(c.mirror.find(z2.handle())->props.at(0).value.s, std::string("Office"));

    auto all = instances<Zone>();
    CHECK_EQ(all.size(), size_t{2});
    CHECK(all[0] == &z1);

    CHECK_THROWS(spawn<Zone>(1, "Duplicate"), std::invalid_argument);
    CHECK_THROWS(spawn<Thermo>(5), std::logic_error);  // a singleton

    const uint32_t h1 = z1.handle();
    const int stopsBefore = Zone::stopCount.load();
    destroy(z1);
    recs = c.settle();
    CHECK_EQ(feed::only(recs, Rec::InstanceRemoved).size(), size_t{1});
    CHECK(c.mirror.find(h1) == nullptr);
    CHECK_EQ(Zone::stopCount.load() - stopsBefore, 1);
    CHECK_EQ(instances<Zone>().size(), size_t{1});
    CHECK_EQ(nativebind_invoke(h1, 0, nullptr, 0, 1), NATIVEBIND_E_NO_INSTANCE);
    CHECK_EQ(nativebind_write(h1, 0, nullptr, 0, 1), NATIVEBIND_E_NO_INSTANCE);
}

TEST(spawn_requires_started_runtime) { CHECK_THROWS(spawn<Zone>(1, "x"), std::logic_error); }

TEST(invoke_on_instance) {
    feed::Started s;
    feed::Consumer c;
    Zone& z = spawn<Zone>(7, "Lab");
    c.settle();
    CHECK_EQ(nativebind_invoke(z.handle(), 0, nullptr, 0, 11), NATIVEBIND_OK);
    c.settle();
    CHECK_EQ(z.temp.get(), 21.0);
    CHECK_EQ(c.mirror.find(z.handle())->props.at(1).value.d, 21.0);
}

TEST(invoke_on_instance_destroyed_before_it_runs_still_completes) {
    feed::Started s;
    feed::Consumer c;
    Zone& z = spawn<Zone>(1, "Gone");
    nativebind_flush(5000);
    const uint32_t h = z.handle();
    // Hold the nativebind thread so destroy and invoke queue up in order.
    std::atomic<bool> release{false};
    post([&] {
        while (!release) std::this_thread::yield();
    });
    destroy(z);
    CHECK_EQ(nativebind_invoke(h, 0, nullptr, 0, 77), NATIVEBIND_OK);
    release = true;
    c.settle();
    bool found = false;
    for (const auto& r : c.mirror.results)
        if (r.callId == 77) {
            found = true;
            CHECK_EQ(r.status, NATIVEBIND_E_NO_INSTANCE);
        }
    CHECK(found);
}

TEST(timers_created_in_constructor_start_when_live_and_stop_on_destroy) {
    feed::Started s;
    Zone& z = spawn<Zone>(1, "Tick", 5);
    CHECK(waitFor([&] { return z.ticks.get() >= 3; }));
    const uint32_t h = z.handle();
    destroy(z);
    nativebind_flush(5000);
    CHECK_EQ(nativebind_invoke(h, 0, nullptr, 0, 1), NATIVEBIND_E_NO_INSTANCE);
    std::this_thread::sleep_for(20ms);  // would crash under ASan if a timer still fired
}

TEST(after_and_cancel) {
    feed::Started s;
    auto& th = singleton<Thermo>();
    std::atomic<int> fired{0};
    th.after(1ms, [&] { ++fired; });
    const TimerId never = th.after(1ms, [&] { fired += 100; });
    th.cancel(never);
    CHECK(waitFor([&] { return fired.load() >= 1; }));
    std::this_thread::sleep_for(10ms);
    CHECK_EQ(fired.load(), 1);
    std::atomic<bool> onThread{false};
    th.post([&] { onThread = onNativeBindThread(); });
    nativebind_flush(5000);
    CHECK(onThread.load());
    CHECK(!onNativeBindThread());
}

TEST(stop_calls_onStop_for_every_module) {
    const int before = Zone::stopCount.load();
    {
        feed::Started s;
        spawn<Zone>(1, "a");
        spawn<Zone>(2, "b");
        nativebind_flush(5000);
    }
    CHECK_EQ(Zone::stopCount.load() - before, 2);
    CHECK(!started());
    CHECK_THROWS(singleton<Thermo>(), std::logic_error);
}

TEST(spawn_while_stopping_is_refused_and_leaves_nothing_behind) {
    bool refused = false;
    {
        feed::Started s;
        spawn<Zone>(1, "a");
        nativebind_flush(5000);
        Zone::stopHook = [&] {
            try {
                spawn<Zone>(99, "late");
            } catch (const std::logic_error&) {
                refused = true;
            }
        };
    }
    Zone::stopHook = nullptr;
    {
        feed::Started s;
        CHECK(instances<Zone>().empty());  // nothing survived into the next run
    }
    CHECK(refused);
}

TEST(restart_creates_fresh_singletons) {
    uint32_t first;
    {
        feed::Started s;
        singleton<Thermo>().setpoint = 25.0;
        first = singleton<Thermo>().handle();
    }
    feed::Started s;
    CHECK(singleton<Thermo>().handle() != first);
    CHECK_EQ(singleton<Thermo>().setpoint.get(), 21.5);
}
