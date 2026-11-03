#include <string>
#include <thread>

#include "feed.hpp"
#include "harness.hpp"
#include "modules/thermo.cpp"  // class definitions only (all inline), safe to include

using namespace nativebind;
using feed::Rec;

namespace {

int typeId(const char* name) { return nativebind_type_id(name); }

const feed::InstanceState& thermoState(const feed::Consumer& c) {
    const auto* s = c.mirror.find(singleton<Thermo>().handle());
    if (!s) t::fail(__FILE__, __LINE__, "Thermo missing from mirror");
    return *s;
}

int32_t write(const Module& m, uint16_t prop, const std::vector<uint8_t>& v, uint32_t seq) {
    return nativebind_write(m.handle(), prop, v.data(), static_cast<uint32_t>(v.size()), seq);
}

int32_t invoke(const Module& m, uint16_t method, const std::vector<uint8_t>& a, uint32_t callId) {
    return nativebind_invoke(m.handle(), method, a.data(), static_cast<uint32_t>(a.size()), callId);
}

const feed::Record* resultFor(const feed::Consumer& c, uint32_t callId) {
    for (const auto& r : c.mirror.results)
        if (r.callId == callId) return &r;
    return nullptr;
}

// Property indexes (declaration order).
enum : uint16_t { kSetpoint, kEnabled, kName, kFanSpeed, kRoomTemp, kStage };
// Method indexes.
enum : uint16_t { mBoost, mAdd, mMakeReading, mFail, mCalibrate };

}  // namespace

TEST(module_works_without_runtime) {
    Thermo t;  // plain object, e.g. for unit tests of module logic
    CHECK(!t.live());
    CHECK_EQ(t.setpoint.get(), 21.5);
    CHECK(t.setpoint.set(22.0));
    CHECK(!t.setpoint.set(22.0));  // unchanged
    t.roomTemp = 19.0;
    CHECK_EQ(static_cast<double>(t.roomTemp), 19.0);
    t.readings.push_back(Reading{"a", 1, {}});
    CHECK_EQ(t.readings.size(), size_t{1});
    t.overTemp(40.0);  // no runtime: nothing to send, must not crash
    CHECK_EQ(t.setpoint.index(), uint16_t{0});
    CHECK_EQ(t.stage.index(), uint16_t{5});
}

TEST(start_creates_singletons_and_resync_describes_everything) {
    feed::Started s;
    feed::Consumer c;
    auto recs = c.pump();
    CHECK(!recs.empty());
    CHECK(recs.front().kind == Rec::Resync);

    const auto added = feed::only(recs, Rec::InstanceAdded);
    CHECK_EQ(added.size(), size_t{2});  // Thermo, Device

    const auto& th = thermoState(c);
    CHECK_EQ(static_cast<int>(th.type), typeId("Thermo"));
    CHECK_EQ(th.props.size(), size_t{6});
    CHECK_EQ(th.props.at(kSetpoint).value.d, 21.5);
    CHECK_EQ(th.props.at(kName).value.s, std::string("Living room"));
    CHECK_EQ(th.props.at(kStage).value.i, int64_t{0});
    CHECK_EQ(th.lists.size(), size_t{1});

    const auto& sp = th.props.at(kSetpoint).meta;
    CHECK_EQ(sp.min, 15.0);
    CHECK_EQ(sp.max, 30.0);
    CHECK_EQ(sp.step, 0.5);
    CHECK_EQ(sp.attr("unit").s, std::string("celsius"));
    CHECK_EQ(sp.flags, uint8_t{1 | 2});  // writable, enabled
    CHECK_EQ(th.props.at(kRoomTemp).meta.flags, uint8_t{2});
    const auto& rt = th.props.at(kRoomTemp).meta;
    CHECK_EQ(rt.attrs.size(), size_t{4});  // every attribute type, in declaration order
    CHECK_EQ(rt.attrs[0].first, std::string("unit"));
    CHECK(rt.attr("decimals").tag == Tag::Int && rt.attr("decimals").i == 1);
    CHECK(rt.attr("trend").tag == Tag::Bool && rt.attr("trend").b);
    CHECK(rt.attr("scale").tag == Tag::Double && rt.attr("scale").d == 0.5);
    CHECK_EQ(th.props.at(kName).meta.label, std::string("Room name"));
    CHECK(th.props.at(kName).meta.attrs.empty());
    CHECK_EQ(th.props.at(kFanSpeed).meta.attr("level").i, int64_t{2});

    CHECK(c.pump().empty());  // nothing new
}

TEST(changes_are_coalesced_and_wake_once) {
    feed::Started s;
    feed::Consumer c;
    c.pump();
    auto& th = singleton<Thermo>();
    const int wakesBefore = c.wakes();
    for (int i = 0; i < 100; ++i) th.roomTemp = 20.0 + i;
    CHECK_EQ(c.wakes() - wakesBefore, 1);
    auto recs = c.pump();
    CHECK_EQ(recs.size(), size_t{1});
    CHECK(recs[0].kind == Rec::Prop);
    CHECK_EQ(recs[0].member, uint16_t{kRoomTemp});
    CHECK_EQ(recs[0].values[0].d, 119.0);
}

TEST(changes_from_other_threads) {
    feed::Started s;
    feed::Consumer c;
    c.pump();
    auto& th = singleton<Thermo>();
    std::thread worker([&] {
        th.roomTemp.set(25.5);
        th.stage = Stage::High;
    });
    worker.join();
    c.pump();
    const auto& st = thermoState(c);
    CHECK_EQ(st.props.at(kRoomTemp).value.d, 25.5);
    CHECK_EQ(st.props.at(kStage).value.i, static_cast<int64_t>(Stage::High));
}

TEST(attribute_changes_are_sent) {
    feed::Started s;
    feed::Consumer c;
    c.pump();
    auto& th = singleton<Thermo>();
    Meta m = th.setpoint.meta();
    m.attrs.push_back({"unit", "fahrenheit"});
    m.attrs.push_back({"hint", std::string("cool")});
    th.setpoint.setMeta(m);
    c.pump();
    const auto& sp = thermoState(c).props.at(kSetpoint).meta;
    CHECK_EQ(sp.attrs.size(), size_t{3});
    CHECK_EQ(sp.attrs[1].second.s, std::string("fahrenheit"));
    CHECK_EQ(sp.attr("hint").s, std::string("cool"));
}

TEST(ui_write_is_clamped_validated_and_acknowledged) {
    feed::Started s;
    feed::Consumer c;
    c.pump();
    auto& th = singleton<Thermo>();

    CHECK_EQ(write(th, kSetpoint, feed::encode(23.0), 1), NATIVEBIND_OK);
    c.settle();
    CHECK_EQ(th.setpoint.get(), 23.0);
    CHECK_EQ(thermoState(c).props.at(kSetpoint).seq, uint32_t{1});
    CHECK_EQ(th.writes, 1);
    CHECK_EQ(th.lastWrite, 23.0);

    CHECK_EQ(write(th, kSetpoint, feed::encode(99.0), 2), NATIVEBIND_OK);  // clamped to max
    c.settle();
    CHECK_EQ(th.setpoint.get(), 30.0);
    CHECK_EQ(thermoState(c).props.at(kSetpoint).value.d, 30.0);

    CHECK_EQ(write(th, kSetpoint, feed::encode(29.0), 3), NATIVEBIND_OK);  // rejected by validator
    auto recs = c.settle();
    CHECK_EQ(th.setpoint.get(), 30.0);
    CHECK_EQ(recs.size(), size_t{1});  // echoed anyway, so the UI reverts
    CHECK_EQ(recs[0].seq, uint32_t{3});
    CHECK_EQ(recs[0].values[0].d, 30.0);
    CHECK_EQ(th.writes, 2);  // onWrite not called for the rejected value

    CHECK_EQ(write(th, kName, feed::encode(std::string("A very long room name indeed")), 4), NATIVEBIND_OK);
    c.settle();
    CHECK_EQ(th.name.get(), std::string("A very long room"));  // validator returned a replacement
}

TEST(ui_write_errors) {
    feed::Started s;
    feed::Consumer c;
    auto& th = singleton<Thermo>();
    CHECK_EQ(write(th, kRoomTemp, feed::encode(1.0), 1), NATIVEBIND_E_READ_ONLY);
    CHECK_EQ(write(th, kSetpoint, feed::encode(std::string("x")), 1), NATIVEBIND_E_TYPE);
    CHECK(std::string(nativebind_last_error()).find("setpoint") != std::string::npos);
    CHECK_EQ(write(th, kSetpoint, feed::encode(1.0, 2.0), 1), NATIVEBIND_E_TYPE);  // trailing data
    CHECK_EQ(write(th, 99, feed::encode(1.0), 1), NATIVEBIND_E_NO_MEMBER);
    CHECK_EQ(nativebind_write(123456, 0, nullptr, 0, 1), NATIVEBIND_E_NO_INSTANCE);
    Thermo::installTestGuard(0);
    CHECK_EQ(write(th, kFanSpeed, feed::encode(int32_t{2}), 1), NATIVEBIND_E_ACCESS);
    CHECK(std::string(nativebind_last_error()).find("fanSpeed: needs level 2") != std::string::npos);
    setGuard(nullptr);

    th.setpoint.setEnabled(false);
    CHECK_EQ(write(th, kSetpoint, feed::encode(22.0), 1), NATIVEBIND_E_DISABLED);
    th.setpoint.setEnabled(true);
    CHECK_EQ(write(th, kSetpoint, feed::encode(22.0), 1), NATIVEBIND_OK);
}

TEST(write_requires_started_runtime) {
    CHECK_EQ(nativebind_write(1, 0, nullptr, 0, 1), NATIVEBIND_E_NOT_STARTED);
    CHECK_EQ(nativebind_invoke(1, 0, nullptr, 0, 1), NATIVEBIND_E_NOT_STARTED);
}

TEST(meta_changes_are_sent) {
    feed::Started s;
    feed::Consumer c;
    c.pump();
    auto& th = singleton<Thermo>();
    th.setpoint.setRange(16, 26);
    th.setpoint.setEnabled(false);
    auto recs = c.pump();
    CHECK_EQ(recs.size(), size_t{1});  // coalesced into one Meta record
    CHECK(recs[0].kind == Rec::Meta);
    CHECK_EQ(recs[0].min, 16.0);
    CHECK_EQ(recs[0].max, 26.0);
    CHECK_EQ(recs[0].flags, uint8_t{1});  // writable, not enabled

    CHECK_EQ(write(th, kSetpoint, feed::encode(10.0), 5), NATIVEBIND_E_DISABLED);
    th.setpoint.setEnabled(true);
    CHECK_EQ(write(th, kSetpoint, feed::encode(10.0), 5), NATIVEBIND_OK);
    c.settle();
    CHECK_EQ(th.setpoint.get(), 16.0);  // new range applies
}

TEST(signals_reach_the_feed_and_cpp_listeners) {
    feed::Started s;
    feed::Consumer c;
    c.pump();
    auto& th = singleton<Thermo>();
    double heard = 0;
    const auto id = th.overTemp.connect([&](double v) { heard = v; });
    th.overTemp(36.5);
    th.note(std::string("filter"), 3);
    th.overTemp.disconnect(id);
    th.overTemp(40.0);
    c.pump();
    CHECK_EQ(heard, 36.5);
    CHECK_EQ(c.mirror.signals.size(), size_t{3});
    CHECK_EQ(c.mirror.signals[0].member, uint16_t{0});
    CHECK_EQ(c.mirror.signals[0].values[0].d, 36.5);
    CHECK_EQ(c.mirror.signals[1].member, uint16_t{1});
    CHECK_EQ(c.mirror.signals[1].values.size(), size_t{2});
    CHECK_EQ(c.mirror.signals[1].values[0].s, std::string("filter"));
    CHECK_EQ(c.mirror.signals[1].values[1].i, int64_t{3});
}

TEST(invoke_methods) {
    feed::Started s;
    feed::Consumer c;
    c.pump();
    auto& th = singleton<Thermo>();

    CHECK_EQ(invoke(th, mBoost, feed::encode(int32_t{30}), 1), NATIVEBIND_OK);
    CHECK_EQ(invoke(th, mAdd, feed::encode(1.5, 2.25), 2), NATIVEBIND_OK);
    CHECK_EQ(invoke(th, mMakeReading, feed::encode(std::string("floor")), 3), NATIVEBIND_OK);
    CHECK_EQ(invoke(th, mFail, {}, 4), NATIVEBIND_OK);
    CHECK_EQ(invoke(th, mCalibrate, feed::encode(0.5), 5), NATIVEBIND_OK);
    CHECK_EQ(invoke(th, mAdd, feed::encode(std::string("x")), 6), NATIVEBIND_OK);
    CHECK_EQ(invoke(th, mBoost, feed::encode(int32_t{1}, int32_t{2}), 7), NATIVEBIND_OK);
    CHECK_EQ(invoke(th, 42, {}, 8), NATIVEBIND_E_NO_MEMBER);
    c.settle();

    CHECK_EQ(th.boostMinutes, 30);
    const auto* r1 = resultFor(c, 1);
    CHECK(r1 && r1->status == NATIVEBIND_OK && r1->values[0].tag == Tag::Void);
    const auto* r2 = resultFor(c, 2);
    CHECK(r2 && r2->status == NATIVEBIND_OK);
    CHECK_EQ(r2->values[0].d, 3.75);
    const auto* r3 = resultFor(c, 3);
    CHECK(r3 && r3->values[0].tag == Tag::Struct);
    CHECK_EQ(r3->values[0].items[0].s, std::string("floor"));
    const auto* r4 = resultFor(c, 4);
    CHECK(r4 && r4->status == NATIVEBIND_E_EXCEPTION);
    CHECK_EQ(r4->error, std::string("boom"));
    const auto* r5 = resultFor(c, 5);
    CHECK(r5 && r5->status == NATIVEBIND_E_ACCESS);
    CHECK_EQ(th.offset(), 0.0);
    const auto* r6 = resultFor(c, 6);
    CHECK(r6 && r6->status == NATIVEBIND_E_TYPE);
    const auto* r7 = resultFor(c, 7);
    CHECK(r7 && r7->status == NATIVEBIND_E_TYPE);
    CHECK(resultFor(c, 8) == nullptr);
}

TEST(guard_decides_writes_and_invokes) {
    feed::Started s;
    feed::Consumer c;
    c.pump();
    auto& th = singleton<Thermo>();
    // No guard: writes pass, INVOKE_AS is refused (fail closed).
    CHECK_EQ(write(th, kFanSpeed, feed::encode(int32_t{2}), 1), NATIVEBIND_OK);
    CHECK_EQ(invoke(th, mCalibrate, feed::encode(0.5), 1), NATIVEBIND_OK);
    c.settle();
    CHECK_EQ(resultFor(c, 1)->status, NATIVEBIND_E_ACCESS);
    CHECK(resultFor(c, 1)->error.find("no nativebind::setGuard") != std::string::npos);
    // Guard at level 1: the level-2 property and the level-2 method are denied.
    Thermo::installTestGuard(1);
    CHECK_EQ(write(th, kFanSpeed, feed::encode(int32_t{1}), 2), NATIVEBIND_E_ACCESS);
    CHECK(std::string(nativebind_last_error()).find("needs level 2") != std::string::npos);
    CHECK_EQ(write(th, kSetpoint, feed::encode(22.0), 3), NATIVEBIND_OK);  // no "level" attribute
    CHECK_EQ(invoke(th, mCalibrate, feed::encode(0.5), 2), NATIVEBIND_OK);
    c.settle();
    CHECK_EQ(resultFor(c, 2)->status, NATIVEBIND_E_ACCESS);
    CHECK_EQ(th.offset(), 0.0);
    // Level 2: allowed.
    Thermo::installTestGuard(2);
    CHECK_EQ(invoke(th, mCalibrate, feed::encode(0.5), 3), NATIVEBIND_OK);
    c.settle();
    CHECK_EQ(resultFor(c, 3)->status, NATIVEBIND_OK);
    CHECK_EQ(write(th, kFanSpeed, feed::encode(int32_t{7}), 4), NATIVEBIND_OK);
    c.settle();
    CHECK_EQ(th.offset(), 0.5);
    CHECK_EQ(th.fanSpeed.get(), 3);  // clamped
}

TEST(attach_starts_over_with_a_resync) {
    feed::Started s;
    feed::Consumer c;
    c.pump();
    auto& th = singleton<Thermo>();
    CHECK_EQ(invoke(th, mAdd, feed::encode(1.0, 1.0), 9), NATIVEBIND_OK);
    nativebind_flush(5000);
    feed::Consumer restarted;  // e.g. a Flutter hot restart
    auto recs = restarted.pump();
    CHECK(recs.front().kind == Rec::Resync);
    CHECK(restarted.mirror.results.empty());  // results of the old isolate are dropped
    CHECK(restarted.mirror.find(th.handle()) != nullptr);
}

TEST(type_registry) {
    CHECK(nativebind_type_count() >= 4);
    const int id = typeId("Thermo");
    CHECK(id >= 0);
    CHECK_EQ(std::string(nativebind_type_name(id)), std::string("Thermo"));
    CHECK(std::string(nativebind_type_schema(id)).rfind("module Thermo singleton\n", 0) == 0);
    CHECK_EQ(typeId("Nope"), NATIVEBIND_E_UNKNOWN_TYPE);
    CHECK(nativebind_type_name(999) == nullptr);
    CHECK_EQ(nativebind_abi_version(), NATIVEBIND_ABI_VERSION);
    CHECK_EQ(std::string(nativebind_status_message(NATIVEBIND_E_ACCESS)), std::string("access denied"));
}
