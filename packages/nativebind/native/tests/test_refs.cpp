// The generated typed references (thermo.nb.hpp), used the way another
// module file would: without the Thermo class definition. Also Prop = Prop.

#include <stdexcept>

#include "feed.hpp"
#include "harness.hpp"
#include "modules/thermo.nb.hpp"

using namespace nativebind;

TEST(typed_references_reach_the_live_module) {
    feed::Started s;
    auto t = ref::Thermo::get();
    t.setpoint = 23.5;
    auto again = ref::Thermo::get();
    CHECK_EQ(again.setpoint.get(), 23.5);
    CHECK_EQ(&t.setpoint, &again.setpoint);
    CHECK_EQ(std::string(t.roomTemp.name()), std::string("roomTemp"));
}

TEST(typed_references_to_missing_instances_throw) {
    feed::Started s;
    CHECK_THROWS(ref::Zone::get(12345), std::out_of_range);
}

TEST(assigning_a_prop_copies_its_value) {
    feed::Started s;
    auto t = ref::Thermo::get();
    t.setpoint = 22.0;
    t.roomTemp = t.setpoint;  // same type
    CHECK_EQ(t.roomTemp.get(), 22.0);
    t.fanSpeed = t.roomTemp;  // converting (double -> int32_t)
    CHECK_EQ(t.fanSpeed.get(), 22);
    t.roomTemp = t.roomTemp;  // self-assignment is a no-op
    CHECK_EQ(t.roomTemp.get(), 22.0);
}
