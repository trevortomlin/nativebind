// Second module file sharing types with air_handler.cpp through a header.

#include <nativebind/nativebind.hpp>

#include "hvac_types.hpp"

using namespace nativebind;

namespace hvac::site {

enum Season { kWinter, kSummer };

/// Whole-building settings.
class Building : public Module {
    NATIVEBIND_MODULE(Building)
public:
    NATIVEBIND_PROP(hvac::Mode, mode, hvac::Mode::Auto)
    NATIVEBIND_PROP(Season, season, kWinter)
    NATIVEBIND_READ(Level, level_required, Level::Technician)
    NATIVEBIND_LIST(ScheduleEntry, holidays)

    NATIVEBIND_INVOKE void set_mode(Mode m) { mode = m; }
};

}  // namespace hvac::site
