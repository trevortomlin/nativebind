#include <nativebind/nativebind.hpp>

#include "sensor_types.hpp"

class Sensor : public nativebind::Module {
    NATIVEBIND_MODULE(Sensor)
public:
    NATIVEBIND_READ(Sample, last, {})
};
