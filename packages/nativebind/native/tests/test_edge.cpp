// Edge cases: C ABI misuse, registration mismatches, timers, validators,
// metadata, concurrent alarms, restart cycles.

#include <atomic>
#include <chrono>
#include <cmath>
#include <limits>
#include <string>
#include <thread>
#include <vector>

#include "feed.hpp"
#include "harness.hpp"
#include "modules/thermo.cpp"  // class definitions only (all inline), safe to include
#include "nativebind/glue.hpp"

using namespace nativebind;
using namespace std::chrono_literals;

// ---------------------------------------------------------------- a module whose glue is wrong

class Mismatched : public Module {
    NATIVEBIND_MODULE(Mismatched, .instanced = true)
public:
    NATIVEBIND_PROP(int32_t, actual, 0)
};

template <>
struct nativebind::glue::Invoker<::Mismatched> {
    static constexpr ModuleOptions options = ::Mismatched::nativebind_options_;
    static void invoke(Module&, uint16_t method, Reader&, Writer&) { unknownMethod("Mismatched", method); }
};

namespace {
// Deliberately stale: the generator "thought" the property is called `other`.
const glue::PropDecl mismatchedProps[] = {{"other", Tag::Int}};
const glue::ModuleType mismatchedType{
    .name = "Mismatched",
    .cppType = &typeid(::Mismatched),
    .instanced = true,
    .order = 0,
    .create = nullptr,
    .invoke = &glue::Invoker<::Mismatched>::invoke,
    .props = mismatchedProps,
    .propCount = 1,
    .listCount = 0,
    .signalCount = 0,
    .methodCount = 0,
    .schema = "module Mismatched instanced\nprop other int rw\n",
};
const glue::Registrar mismatchedRegistrar{mismatchedType};

bool waitFor(const std::function<bool()>& cond, std::chrono::milliseconds timeout = 3s) {
    const auto end = std::chrono::steady_clock::now() + timeout;
    while (std::chrono::steady_clock::now() < end) {
        if (cond()) return true;
        std::this_thread::sleep_for(1ms);
    }
    return cond();
}

int32_t writeValue(const Module& m, uint16_t prop, const std::vector<uint8_t>& v, uint32_t seq) {
    return nativebind_write(m.handle(), prop, v.data(), static_cast<uint32_t>(v.size()), seq);
}
}  // namespace

TEST(stale_generated_code_is_detected_at_adoption) {
    feed::Started s;
    bool threw = false;
    try {
        spawn<Mismatched>(1);
    } catch (const std::logic_error& e) {
        const std::string msg = e.what();
        // Names the real tool, not an old command that does not exist.
        threw = msg.find("nativebind_generator") != std::string::npos &&
                msg.find("nativebind generate") == std::string::npos;
    }
    CHECK(threw);
    CHECK(instances<Mismatched>().empty());
}

TEST(abi_tolerates_null_and_empty_arguments) {
    CHECK_EQ(nativebind_type_id(nullptr), NATIVEBIND_E_UNKNOWN_TYPE);
    CHECK(nativebind_type_schema(-1) == nullptr);
    CHECK(nativebind_type_name(1 << 20) == nullptr);
    feed::Started s;
    feed::Consumer c;
    CHECK(nativebind_drain(nullptr) != nullptr || true);  // must not crash without out_len
    uint32_t len = 1;
    (void)nativebind_drain(&len);
    (void)nativebind_drain(&len);
    CHECK_EQ(len, uint32_t{0});  // nothing new
    auto& th = singleton<Thermo>();
    CHECK_EQ(nativebind_invoke(th.handle(), 3, nullptr, 0, 1), NATIVEBIND_OK);  // fail(): no arguments
    CHECK_EQ(nativebind_write(th.handle(), 0, nullptr, 0, 1), NATIVEBIND_E_TYPE);
    for (int32_t s2 = 1; s2 >= -12; --s2) CHECK(std::string(nativebind_status_message(s2)).size() > 0);
}

TEST(abi_last_error_is_per_thread) {
    feed::Started s;
    auto& th = singleton<Thermo>();
    CHECK_EQ(nativebind_write(th.handle(), 4, nullptr, 0, 1), NATIVEBIND_E_READ_ONLY);
    const std::string mine = nativebind_last_error();
    std::string other;
    std::thread t([&] {
        nativebind_write(123456, 0, nullptr, 0, 1);
        other = nativebind_last_error();
    });
    t.join();
    CHECK(mine.find("read-only") != std::string::npos);
    CHECK(other.find("no instance") != std::string::npos);
    CHECK_EQ(std::string(nativebind_last_error()), mine);
}

TEST(abi_detach_and_reattach) {
    feed::Started s;
    std::atomic<int> wakes{0};
    nativebind_attach_callback([](void* u) { static_cast<std::atomic<int>*>(u)->fetch_add(1); }, &wakes);
    uint32_t len = 0;
    nativebind_drain(&len);
    nativebind_attach_callback(nullptr, nullptr);  // detached: changes must not call anything
    singleton<Thermo>().roomTemp = 33.0;
    const int before = wakes.load();
    singleton<Thermo>().roomTemp = 34.0;
    CHECK_EQ(wakes.load(), before);
    nativebind_attach_port(0);  // no Dart port either
    feed::Consumer c;       // reattach: full state again
    CHECK(c.pump().front().kind == feed::Rec::Resync);
}

TEST(restart_cycles_leave_nothing_behind) {
    for (int i = 0; i < 15; ++i) {
        feed::Started s;
        feed::Consumer c;
        c.pump();
        auto& th = singleton<Thermo>();
        spawn<Zone>(1, "z", 1);
        th.readings.push_back(Reading{"x", 1, {}});
        th.overTemp(1.0);
        auto v = feed::encode(22.0);
        nativebind_write(th.handle(), 0, v.data(), static_cast<uint32_t>(v.size()), 1);
        nativebind_invoke(th.handle(), 1, nullptr, 0, 2);  // add() with missing args -> type error result
        c.settle();
    }
    CHECK(!started());
}

TEST(validators_of_every_shape) {
    feed::Started s;
    feed::Consumer c;
    auto& th = singleton<Thermo>();
    // setpoint: bool validator (rejects 29); name: replacement validator (truncates).
    CHECK_EQ(writeValue(th, 0, feed::encode(29.0), 1), NATIVEBIND_OK);
    CHECK_EQ(writeValue(th, 2, feed::encode(std::string(40, 'a')), 2), NATIVEBIND_OK);
    c.settle();
    CHECK_EQ(th.setpoint.get(), 21.5);
    CHECK_EQ(th.name.get().size(), size_t{16});
    // optional-returning validator on a plain object
    Thermo local;
    local.enabled.validate([](bool v) -> std::optional<bool> {
        if (v) return std::nullopt;
        return v;
    });
    (void)local;
}

TEST(integer_properties_clamp_to_whole_bounds) {
    feed::Started s;
    feed::Consumer c;
    auto& th = singleton<Thermo>();
    th.fanSpeed.setRange(0.5, 2.5);  // fractional bounds on an int property
    CHECK_EQ(writeValue(th, 3, feed::encode(int32_t{-10}), 1), NATIVEBIND_OK);
    c.settle();
    CHECK_EQ(th.fanSpeed.get(), 1);  // ceil(0.5)
    CHECK_EQ(writeValue(th, 3, feed::encode(int32_t{10}), 2), NATIVEBIND_OK);
    c.settle();
    CHECK_EQ(th.fanSpeed.get(), 2);  // floor(2.5)
}

TEST(meta_updates_encode_every_field) {
    feed::Started s;
    feed::Consumer c;
    c.pump();
    auto& th = singleton<Thermo>();
    Meta m;
    m.min = -5;
    m.max = 5;
    m.step = 0.25;
    m.label = "Pressure";
    m.attrs = {{"unit", 21}, {"decimals", 2}, {"confirm", true}, {"note", "kPa"}};
    th.setpoint.setMeta(m);
    th.setpoint.setStep(0.5);
    auto recs = c.pump();
    CHECK_EQ(recs.size(), size_t{1});
    const auto& r = recs[0];
    CHECK_EQ(r.min, -5.0);
    CHECK_EQ(r.max, 5.0);
    CHECK_EQ(r.step, 0.5);
    CHECK_EQ(r.label, std::string("Pressure"));
    CHECK_EQ(r.flags, uint8_t{1 | 2});
    CHECK_EQ(r.attrs.size(), size_t{4});
    CHECK_EQ(r.attrs[0].second.i, int64_t{21});
    CHECK(r.attrs[2].second.b);
    CHECK_EQ(r.attrs[3].second.s, std::string("kPa"));
    // unchanged range/step: no record
    th.setpoint.setRange(-5, 5);
    th.setpoint.setStep(0.5);
    CHECK(c.pump().empty());
}

TEST(meta_label_may_come_from_a_temporary_string) {
    feed::Started s;
    feed::Consumer c;
    c.pump();
    auto& th = singleton<Thermo>();
    {
        std::string name = "Zone " + std::to_string(42) + " setpoint, long enough to live on the heap";
        Meta m = th.setpoint.meta();
        m.label = name.c_str();
        th.setpoint.setMeta(m);
        name.assign(name.size(), 'x');  // the caller reuses its buffer...
    }  // ...and frees it before the feed is read
    auto recs = c.pump();
    CHECK_EQ(recs.size(), size_t{1});
    CHECK_EQ(recs[0].label, std::string("Zone 42 setpoint, long enough to live on the heap"));
    CHECK_EQ(th.setpoint.meta().label, std::string("Zone 42 setpoint, long enough to live on the heap"));
}

TEST(nan_and_infinity_cross_the_binding) {
    feed::Started s;
    feed::Consumer c;
    c.pump();
    auto& th = singleton<Thermo>();
    th.roomTemp = std::numeric_limits<double>::quiet_NaN();
    c.pump();
    CHECK(std::isnan(c.mirror.find(th.handle())->props.at(4).value.d));
    th.roomTemp = std::numeric_limits<double>::infinity();
    c.pump();
    CHECK(std::isinf(c.mirror.find(th.handle())->props.at(4).value.d));
}

TEST(timers_fire_in_order_and_survive_self_cancel) {
    feed::Started s;
    auto& th = singleton<Thermo>();
    std::vector<int> order;
    std::mutex m;
    th.after(30ms, [&] {
        std::lock_guard g(m);
        order.push_back(3);
    });
    th.after(10ms, [&] {
        std::lock_guard g(m);
        order.push_back(1);
    });
    th.after(20ms, [&] {
        std::lock_guard g(m);
        order.push_back(2);
    });
    std::atomic<int> ticks{0};
    // Atomic because this test arms the timer from the main thread; in a module,
    // every() is called on the nativebind thread (onStart) where the timer also runs.
    std::atomic<TimerId> id{0};
    id = th.every(2ms, [&] {
        if (++ticks == 3) th.cancel(id.load());  // cancel from inside the callback
    });
    CHECK(waitFor([&] {
        std::lock_guard g(m);
        return order.size() == 3;
    }));
    std::this_thread::sleep_for(20ms);
    std::lock_guard g(m);
    CHECK((order == std::vector<int>{1, 2, 3}));
    CHECK_EQ(ticks.load(), 3);
}

TEST(periodic_timer_period_is_respected) {
    feed::Started s;
    auto& th = singleton<Thermo>();
    std::atomic<int> n{0};
    th.every(10ms, [&] { ++n; });
    std::this_thread::sleep_for(205ms);
    const int got = n.load();
    CHECK(got >= 12);  // ~20 expected; generous for loaded CI machines
    CHECK(got <= 22);
}

TEST(stop_from_the_nativebind_thread_is_refused_and_changes_nothing) {
    feed::Started s;
    spawn<Zone>(21, "caller");
    const int stopsBefore = Zone::stopCount.load();
    std::string error;
    post([&] {
        try {
            nativebind::stop();  // would destroy the module whose code is running
        } catch (const std::logic_error& e) {
            error = e.what();
        }
    });
    CHECK(flush());
    CHECK(error.find("nativebind thread") != std::string::npos);
    CHECK_EQ(Zone::stopCount.load(), stopsBefore);  // no onStop ran
    CHECK(started());
    CHECK_EQ(instances<Zone>().size(), size_t{1});
    nativebind::stop();  // from another thread it still works
    CHECK(!started());
    CHECK_EQ(Zone::stopCount.load(), stopsBefore + 1);
}

