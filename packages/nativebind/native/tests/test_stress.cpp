// Many threads change props and lists, spawn and destroy instances and write
// from the "UI" while a consumer drains concurrently. Afterwards the mirror
// must equal the C++ state exactly. Run under -DNATIVEBIND_SANITIZE=thread too.

#include <atomic>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include "feed.hpp"
#include "harness.hpp"
#include "modules/thermo.cpp"  // class definitions only (all inline), safe to include

using namespace nativebind;

TEST(stress_concurrent_producers_and_consumer) {
    feed::Started s;
    feed::Consumer c;
    auto& th = singleton<Thermo>();
    std::atomic<bool> done{false};

    std::thread consumer([&] {
        while (!done) {
            c.pump();
            std::this_thread::yield();
        }
    });

    std::vector<std::thread> producers;
    for (int p = 0; p < 4; ++p) {
        producers.emplace_back([&, p] {
            std::mt19937 rng(static_cast<unsigned>(p));
            for (int i = 0; i < 3000; ++i) {
                switch (rng() % 7) {
                    case 0: th.roomTemp = static_cast<double>(rng() % 400) / 10.0; break;
                    case 1: th.stage = static_cast<Stage>(rng() % 3); break;
                    case 2: th.readings.push_back(Reading{"p" + std::to_string(p), double(i), {}}); break;
                    case 3:
                        if (th.readings.size() > 0) {
                            try {
                                th.readings.erase(0);
                            } catch (const std::out_of_range&) {  // another thread emptied it
                            }
                        }
                        break;
                    case 4: {
                        auto v = feed::encode(15.0 + static_cast<double>(rng() % 30) / 2.0);
                        nativebind_write(th.handle(), 0, v.data(), static_cast<uint32_t>(v.size()), static_cast<uint32_t>(i));
                        break;
                    }
                    case 5: th.overTemp(1.0); break;
                    case 6: {
                        const uint64_t key = static_cast<uint64_t>(p) * 1000000 + static_cast<uint64_t>(i);
                        Zone& z = spawn<Zone>(key, "z");
                        z.temp = 1.0;
                        if (rng() % 2) destroy(z);
                        break;
                    }
                }
            }
        });
    }
    for (auto& t : producers) t.join();
    done = true;
    consumer.join();
    c.settle();

    CHECK_EQ(c.mirror.gaps, 0);
    const auto* inst = c.mirror.find(th.handle());
    CHECK(inst != nullptr);
    CHECK(inst->props.at(4).value == feed::valueOf(th.roomTemp.get()));
    CHECK(inst->props.at(5).value == feed::valueOf(th.stage.get()));
    CHECK(inst->props.at(0).value == feed::valueOf(th.setpoint.get()));
    const auto items = th.readings.items();
    CHECK_EQ(inst->lists.at(0).items.size(), items.size());
    for (size_t i = 0; i < items.size(); ++i) CHECK(inst->lists.at(0).items[i] == feed::valueOf(items[i]));

    size_t zones = 0;
    for (const auto& [h, st] : c.mirror.instances)
        if (static_cast<int>(st.type) == nativebind_type_id("Zone")) ++zones;
    CHECK_EQ(zones, instances<Zone>().size());
}
