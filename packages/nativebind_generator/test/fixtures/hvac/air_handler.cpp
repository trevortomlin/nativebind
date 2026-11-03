// Fixture for the generator tests: exercises namespaces, nested types,
// aliases, header types, builtin types, qualifiers and out-of-line methods.

#include <nativebind/nativebind.hpp>

#include <map>
#include <string>
#include <string_view>
#include <vector>

#include "hvac_types.hpp"

namespace hvac {

namespace {
constexpr double kMaxSupply = 55.0;
const char* const kRaw = R"(not a "string" { with braces })";
}  // namespace

/** Air handling unit with a supply fan and heating/cooling coils. */
class AirHandler final : public nativebind::Module {
    NATIVEBIND_MODULE(AirHandler, .instanced = true)
public:
    enum class FanState { Stopped, Starting, Running, Fault };

    struct Trend {
        std::chrono::system_clock::time_point at;
        Celsius value = 0;
        bool operator==(const Trend&) const = default;
    };

    /// Supply air temperature setpoint.
    NATIVEBIND_PROP(Celsius, supply_setpoint, 18.0, .min = 10, .max = kMaxSupply, .step = 0.5,
                .attrs = {{"unit", "celsius"}, {"decimals", 1}})
    NATIVEBIND_PROP(Mode, mode, Mode::Off)
    NATIVEBIND_READ(FanState, fan_state, FanState::Stopped)
    NATIVEBIND_READ(std::optional<double>, co2, std::nullopt, .attrs = {{"unit", "ppm"}})
    NATIVEBIND_READ(Severity, worst, Severity::Info)
    NATIVEBIND_READ(std::chrono::seconds, runtime, std::chrono::seconds{0})
    NATIVEBIND_READ(std::vector<std::string>, notes, {})
    NATIVEBIND_LIST(ScheduleEntry, schedule)
    NATIVEBIND_LIST(Trend, trend);
    NATIVEBIND_SIGNAL(filterDirty)
    NATIVEBIND_SIGNAL(tripped, std::string, Severity)

    explicit AirHandler(int id) : id_(id), name_{"AHU"}, lookup_{{1, 2}} {
        supply_setpoint.validate([](double v) { return v <= kMaxSupply; });
        if (id_ > 0) {
            struct Local {
                int x;
            };
            (void)Local{1};
        }
    }

    /// Starts the supply fan.
    NATIVEBIND_INVOKE bool start() noexcept { return true; }

    /// Human-readable status.
    NATIVEBIND_INVOKE [[nodiscard]] std::string describe(std::string_view prefix, int verbosity = 1) const;

    NATIVEBIND_INVOKE auto schedule_for(int day) const -> std::vector<ScheduleEntry>;

    NATIVEBIND_INVOKE_AS(Level::Technician) void set_override(std::optional<Mode> mode,
                                                        std::chrono::minutes duration);

    NATIVEBIND_INVOKE void apply(const ScheduleEntry& entry) { schedule.push_back(entry); }

    NATIVEBIND_INVOKE std::vector<Trend> history(std::chrono::system_clock::time_point since) const { return {}; }

    NATIVEBIND_INVOKE Fault last_fault() const { return {}; }

private:
    NATIVEBIND_INVOKE void reset_alarms();

    int id_;
    std::string name_;
    std::map<int, int> lookup_;  // not bound
};

std::string AirHandler::describe(std::string_view prefix, int verbosity) const {
    return std::string(prefix) + name_ + std::to_string(verbosity);
}

std::vector<ScheduleEntry> AirHandler::schedule_for(int day) const {
    std::vector<ScheduleEntry> out;
    for (const auto& e : schedule.items())
        if (e.day == day) out.push_back(e);
    return out;
}

void AirHandler::set_override(std::optional<Mode>, std::chrono::minutes) {}

void AirHandler::reset_alarms() { (void)kRaw; }

}  // namespace hvac
