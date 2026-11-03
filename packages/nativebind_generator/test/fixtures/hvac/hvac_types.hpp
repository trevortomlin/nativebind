#pragma once
// Shared types used by several modules (fixture for the generator tests).

#include <chrono>
#include <cstdint>
#include <optional>
#include <string>

namespace hvac {

/// Operating mode of a unit.
enum class Mode : uint8_t {
    Off,
    Heat,
    Cool,
    /// Picks heat or cool from the room temperature.
    Auto = 10,
    Dry = Auto + 1,
    FAN_ONLY = 1 << 5,
};

/// One entry of a weekly schedule.
struct ScheduleEntry {
    /// Day of week, 0 = Monday.
    int day = 0;
    std::chrono::minutes start{std::chrono::minutes(390)};
    double heatSetpoint = 20.5;
    double coolSetpoint{24.f};
    Mode mode = Mode::Auto;
    std::string label = "Wake \"up\"";
    std::optional<double> humidity;
    uint32_t flags = 0x1'0;

    bool operator==(const ScheduleEntry&) const = default;
};

using Celsius = double;

/// Severity of a fault, most severe last.
enum class Severity : int32_t { Info, Warning, Major, Critical };

/// Access levels; NATIVEBIND_INVOKE_AS takes one as its permission.
enum class Level : uint8_t { User, Technician = 2 };

/// A recorded fault.
struct Fault {
    std::string id;
    Severity severity = Severity::Info;
    std::optional<std::chrono::system_clock::time_point> cleared;
    bool operator==(const Fault&) const = default;
};

}  // namespace hvac
