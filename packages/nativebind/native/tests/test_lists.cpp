#include <string>
#include <vector>

#include "feed.hpp"
#include "harness.hpp"
#include "modules/thermo.cpp"  // class definitions only (all inline), safe to include

using namespace nativebind;
using feed::Rec;

namespace {

Reading R(const std::string& name, double v = 0) { return Reading{name, v, {}}; }

/// The mirror's list must equal the C++ list item by item.
void checkMirror(const feed::Consumer& c, const Thermo& th) {
    const auto* inst = c.mirror.find(th.handle());
    CHECK(inst != nullptr);
    const auto& mirrored = inst->lists.at(0).items;
    const auto actual = th.readings.items();
    CHECK_EQ(mirrored.size(), actual.size());
    for (size_t i = 0; i < actual.size(); ++i) CHECK(mirrored[i] == feed::valueOf(actual[i]));
    CHECK_EQ(c.mirror.gaps, 0);
}

std::vector<std::string> names(const Thermo& th) {
    std::vector<std::string> out;
    for (const auto& r : th.readings.items()) out.push_back(r.sensor);
    return out;
}

}  // namespace

TEST(list_operations_are_incremental) {
    feed::Started s;
    feed::Consumer c;
    c.pump();
    auto& th = singleton<Thermo>();
    th.readings.push_back(R("a"));
    th.readings.push_back(R("b"));
    th.readings.insert(0, R("z"));
    th.readings.set(1, R("a", 5));
    th.readings.update(2, [](Reading& r) { r.value = 7; });
    th.readings.move(0, 2);
    th.readings.erase(0);
    auto recs = c.pump();
    CHECK_EQ(recs.size(), size_t{7});
    CHECK(recs[0].kind == Rec::ListInsert);
    CHECK(recs[3].kind == Rec::ListUpdate);
    CHECK(recs[5].kind == Rec::ListMove);
    CHECK(recs[6].kind == Rec::ListRemove);
    for (size_t i = 1; i < recs.size(); ++i) CHECK_EQ(recs[i].version, recs[i - 1].version + 1);
    checkMirror(c, th);
    CHECK((names(th) == std::vector<std::string>{"b", "z"}));
}

TEST(list_noop_updates_send_nothing) {
    feed::Started s;
    feed::Consumer c;
    auto& th = singleton<Thermo>();
    th.readings.push_back(R("a", 1));
    c.pump();
    th.readings.set(0, R("a", 1));
    th.readings.update(0, [](Reading&) {});
    th.readings.move(0, 0);
    th.readings.erase(0, 0);
    CHECK(c.pump().empty());
}

TEST(list_assign_and_clear_reset) {
    feed::Started s;
    feed::Consumer c;
    c.pump();
    auto& th = singleton<Thermo>();
    th.readings.assign({R("a"), R("b"), R("c")});
    th.readings.clear();
    th.readings.clear();  // already empty: no record
    auto recs = c.pump();
    CHECK_EQ(recs.size(), size_t{2});
    CHECK(recs[0].kind == Rec::ListReset && recs[0].count == 3);
    CHECK(recs[1].kind == Rec::ListReset && recs[1].count == 0);
    checkMirror(c, th);
}

TEST(list_bounds_are_checked) {
    Thermo th;
    CHECK_THROWS(th.readings.at(0), std::out_of_range);
    CHECK_THROWS(th.readings.erase(0), std::out_of_range);
    CHECK_THROWS(th.readings.insert(1, R("x")), std::out_of_range);
    th.readings.insert(0, R("x"));
    CHECK_THROWS(th.readings.move(0, 1), std::out_of_range);
    CHECK_THROWS(th.readings.erase(0, 2), std::out_of_range);
}

TEST(list_sync_keeps_identity_with_minimal_operations) {
    feed::Started s;
    feed::Consumer c;
    auto& th = singleton<Thermo>();
    th.readings.assign({R("a", 1), R("b", 2), R("c", 3), R("d", 4)});
    c.pump();
    auto key = [](const Reading& r) { return r.sensor; };

    // remove b, update c, move d to the front, add e
    th.readings.sync({R("d", 4), R("a", 1), R("c", 30), R("e", 5)}, key);
    auto recs = c.pump();
    CHECK((names(th) == std::vector<std::string>{"d", "a", "c", "e"}));
    CHECK_EQ(th.readings.at(2).value, 30.0);
    CHECK(feed::only(recs, Rec::ListReset).empty());
    CHECK_EQ(feed::only(recs, Rec::ListRemove).size(), size_t{1});
    CHECK_EQ(feed::only(recs, Rec::ListInsert).size(), size_t{1});
    CHECK_EQ(feed::only(recs, Rec::ListUpdate).size(), size_t{1});
    CHECK_EQ(feed::only(recs, Rec::ListMove).size(), size_t{1});
    checkMirror(c, th);

    th.readings.sync({R("d", 4), R("a", 1), R("c", 30), R("e", 5)}, key);  // already equal
    CHECK(c.pump().empty());

    th.readings.sync({}, key);
    c.pump();
    CHECK(th.readings.empty());
    checkMirror(c, th);

    // reverse order
    th.readings.assign({R("1"), R("2"), R("3"), R("4"), R("5")});
    th.readings.sync({R("5"), R("4"), R("3"), R("2"), R("1")}, key);
    c.pump();
    CHECK((names(th) == std::vector<std::string>{"5", "4", "3", "2", "1"}));
    checkMirror(c, th);
}

TEST(list_eraseIf_and_findIndex) {
    Thermo th;
    th.readings.assign({R("a", 1), R("b", 2), R("c", 3)});
    CHECK_EQ(th.readings.eraseIf([](const Reading& r) { return r.value >= 2; }), size_t{2});
    CHECK(th.readings.findIndex([](const Reading& r) { return r.sensor == "a"; }) == std::optional<size_t>{0});
    CHECK(!th.readings.findIndex([](const Reading& r) { return r.sensor == "c"; }));
}

TEST(list_ops_already_in_a_resync_are_ignored) {
    feed::Started s;
    feed::Consumer c;
    auto& th = singleton<Thermo>();
    c.pump();
    th.readings.push_back(R("a"));
    th.readings.push_back(R("b"));
    nativebind_request_resync();  // queued ops are superseded by the full state
    th.readings.push_back(R("c"));
    c.pump();
    th.readings.push_back(R("d"));
    c.pump();
    checkMirror(c, th);
    CHECK((names(th) == std::vector<std::string>{"a", "b", "c", "d"}));
}

TEST(feed_overflow_turns_into_a_resync) {
    feed::Started s;
    feed::Consumer c;
    c.pump();
    auto& th = singleton<Thermo>();
    const std::string big(1024, 'x');
    for (int i = 0; i < 5000; ++i) th.readings.push_back(R(big + std::to_string(i)));  // > 4 MB queued
    auto recs = c.pump();
    CHECK(recs.front().kind == Rec::Resync);
    CHECK_EQ(c.mirror.resyncs, 2);
    checkMirror(c, th);
}
