// C++ listeners of signals: disconnect waits for running calls, and
// connections owned by a module end with it.

#include <atomic>
#include <chrono>
#include <thread>

#include "feed.hpp"
#include "harness.hpp"
#include "modules/thermo.cpp"  // class definitions only (all inline), safe to include

using namespace nativebind;
using namespace std::chrono_literals;

namespace {

bool waitFor(const std::function<bool()>& cond, std::chrono::milliseconds timeout = 2s) {
    const auto end = std::chrono::steady_clock::now() + timeout;
    while (std::chrono::steady_clock::now() < end) {
        if (cond()) return true;
        std::this_thread::sleep_for(1ms);
    }
    return cond();
}

}  // namespace

TEST(disconnect_waits_for_a_listener_that_is_running) {
    feed::Started s;
    auto& th = singleton<Thermo>();
    std::atomic<bool> entered{false}, finished{false};
    const auto id = th.overTemp.connect([&](double) {
        entered = true;
        std::this_thread::sleep_for(100ms);
        finished = true;
    });
    std::thread emitter([&] { th.overTemp(40.0); });
    CHECK(waitFor([&] { return entered.load(); }));
    th.overTemp.disconnect(id);
    // After disconnect returns, the listener (and what it captured) is no
    // longer in use: the caller may destroy it.
    const bool done = finished.load();
    emitter.join();
    CHECK(done);
}

TEST(a_listener_may_disconnect_itself) {
    feed::Started s;
    auto& th = singleton<Thermo>();
    int calls = 0;
    uint64_t id = 0;
    id = th.overTemp.connect([&](double) {
        ++calls;
        th.overTemp.disconnect(id);  // must not wait for itself
        th.overTemp(1.0);            // nested emit: no longer connected
    });
    th.overTemp(40.0);
    th.overTemp(41.0);
    CHECK_EQ(calls, 1);
}

namespace {
// A module the runtime never adopts, so it can be destroyed at any time.
struct Bare : Module {
    Signal<int> ping{this, "ping"};
};
}  // namespace

TEST(a_connection_owned_by_a_module_ends_when_the_module_is_destroyed) {
    feed::Started s;
    auto& th = singleton<Thermo>();
    Zone& z = spawn<Zone>(7, "listener");
    std::atomic<int> calls{0};
    th.overTemp.connect(z, [&calls, &z](double) {
        z.bump();  // uses the owner: must never run once it is gone
        ++calls;
    });
    th.overTemp(40.0);
    CHECK_EQ(calls.load(), 1);
    destroy(z);
    CHECK(flush());
    th.overTemp(41.0);
    CHECK_EQ(calls.load(), 1);
}

TEST(an_owned_connection_outlived_by_its_owner_is_harmless) {
    feed::Started s;
    Zone& z = spawn<Zone>(8, "listener");
    int calls = 0;
    {
        Bare b;
        b.ping.connect(z, [&calls](int) { ++calls; });
        b.ping(1);
    }  // the signal goes first
    destroy(z);  // the owner's cleanup must not touch the destroyed signal
    CHECK(flush());
    CHECK_EQ(calls, 1);
}

TEST(signals_survive_a_pending_resync) {
    feed::Started s;
    auto& th = singleton<Thermo>();
    feed::Consumer c;  // attaching requests a full resync
    th.overTemp(40.0);  // emitted before that resync was drained
    c.pump();
    CHECK_EQ(c.mirror.signals.size(), size_t{1});
    th.overTemp(41.0);  // queued...
    nativebind_request_resync();  // ...then the queue is superseded by a full state
    th.note(std::string("after"), 2);
    c.pump();
    CHECK_EQ(c.mirror.signals.size(), size_t{3});
    CHECK_EQ(c.mirror.signals[1].values[0].d, 41.0);
    CHECK_EQ(c.mirror.signals[2].values[0].s, std::string("after"));
}

TEST(signals_are_not_queued_without_a_consumer) {
    feed::Started s;
    auto& th = singleton<Thermo>();
    for (int i = 0; i < 1000; ++i) th.overTemp(double(i));  // nobody is listening
    feed::Consumer c;
    c.pump();
    CHECK(c.mirror.signals.empty());
}
