// Test modules, written exactly like application modules: one file, no
// header, no FFI. thermo.nb.cpp is the glue nativebind_generator produces.

#include <nativebind/nativebind.hpp>

#include <functional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

enum class Stage { Off, Low, High };

struct Reading {
    std::string sensor;
    double value = 0;
    std::vector<int32_t> history;

    bool operator==(const Reading&) const = default;
};

class Thermo : public nativebind::Module {
    NATIVEBIND_MODULE(Thermo)
public:
    /// Target room temperature.
    NATIVEBIND_PROP(double, setpoint, 21.5, .min = 15, .max = 30, .step = 0.5, .attrs = {{"unit", "celsius"}})
    NATIVEBIND_PROP(bool, enabled, true)
    NATIVEBIND_PROP(std::string, name, "Living room", .label = "Room name")
    NATIVEBIND_PROP(int32_t, fanSpeed, 1, .min = 0, .max = 3, .attrs = {{"level", 2}})
    NATIVEBIND_READ(double, roomTemp, 20.0, .attrs = {{"unit", "celsius"}, {"decimals", 1}, {"trend", true}, {"scale", 0.5}})
    NATIVEBIND_READ(Stage, stage, Stage::Off)
    NATIVEBIND_LIST(Reading, readings)
    NATIVEBIND_SIGNAL(overTemp, double)
    NATIVEBIND_SIGNAL(note, std::string, int32_t)

    NATIVEBIND_INVOKE void boost(int32_t minutes) { boostMinutes = minutes; }
    NATIVEBIND_INVOKE double add(double a, double b) { return a + b; }
    NATIVEBIND_INVOKE Reading makeReading(const std::string& sensor) { return Reading{sensor, 1.5, {1, 2}}; }
    NATIVEBIND_INVOKE void fail() { throw std::runtime_error("boom"); }
    NATIVEBIND_INVOKE_AS(2) void calibrate(double offset) { offset_ = offset; }

    // Used by the Dart integration tests to drive the C++ side.
    NATIVEBIND_INVOKE void spawnZone(int32_t key, std::string label);
    NATIVEBIND_INVOKE void destroyZone(int32_t key);
    NATIVEBIND_INVOKE void emitOverTemp(double t) { overTemp(t); }
    NATIVEBIND_INVOKE void addReading(Reading r) { readings.push_back(std::move(r)); }
    NATIVEBIND_INVOKE void setRoomTemp(double t) { roomTemp = t; }
    NATIVEBIND_INVOKE void limitSetpoint(double max) { setpoint.setRange(15, max); }
    /// A test access policy: the UI is at `level`; writes need the "level"
    /// attribute (default 0) and invokes their permission to be <= level.
    NATIVEBIND_INVOKE void installGuard(int32_t level) { installTestGuard(level); }

    static void installTestGuard(int64_t level) {
        nativebind::setGuard([level](const nativebind::GuardRequest& r) -> std::string {
            int64_t need = r.permission;
            if (r.meta)
                for (const auto& a : r.meta->attrs)
                    if (a.key == "level") need = std::get<int64_t>(a.value.get());
            return need <= level ? "" : "needs level " + std::to_string(need);
        });
    }

    Thermo() {
        setpoint.validate([](double v) { return v != 29.0; });  // tests: 29 is rejected
        setpoint.onWrite([this](double v) {
            ++writes;
            lastWrite = v;
        });
        name.validate([](const std::string& s) { return s.substr(0, 16); });  // truncates
    }

    int writes = 0;
    double lastWrite = 0;
    int boostMinutes = 0;
    double offset() const { return offset_; }

private:
    double offset_ = 0;
};

class Zone : public nativebind::Module {
    NATIVEBIND_MODULE(Zone, .instanced = true)
public:
    NATIVEBIND_PROP(std::string, label, "")
    NATIVEBIND_READ(double, temp, 20.0)
    NATIVEBIND_READ(int32_t, ticks, 0)

    NATIVEBIND_INVOKE void bump() { temp = temp + 1; }

    explicit Zone(std::string l, int tickMs = 0) : tickMs_(tickMs) {
        label = std::move(l);
        if (tickMs_ > 0) every(std::chrono::milliseconds(tickMs_), [this] { ticks = ticks + 1; });
    }

    std::atomic<bool> started{false};
    static inline std::atomic<int> stopCount{0};
    static inline std::function<void()> stopHook;  // tests: runs in onStop

protected:
    void onStart() override { started = true; }
    void onStop() override {
        ++stopCount;
        if (stopHook) stopHook();
    }

private:
    int tickMs_;
};

// Out-of-line definitions (Zone must be complete).
inline void Thermo::spawnZone(int32_t key, std::string label) { nativebind::spawn<Zone>(static_cast<uint64_t>(key), std::move(label)); }

inline void Thermo::destroyZone(int32_t key) {
    for (Zone* z : nativebind::instances<Zone>())
        if (z->key() == static_cast<uint64_t>(key)) nativebind::destroy(*z);
}
