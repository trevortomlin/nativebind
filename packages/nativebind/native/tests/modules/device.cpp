// Test module: a field device polled by its own worker thread.

#include <nativebind/nativebind.hpp>

#include <atomic>
#include <chrono>
#include <cstdint>

/// A simulated field device (think Modbus) with its own I/O thread.
class Device : public nativebind::Module {
    NATIVEBIND_MODULE(Device)
public:
    /// Invariant kept by every poll: a + b == 100.
    NATIVEBIND_READ(int32_t, a, 0)
    NATIVEBIND_READ(int32_t, b, 100)
    NATIVEBIND_READ(int64_t, polls, 0)
    NATIVEBIND_PROP(double, setpoint, 10.0, .min = 0, .max = 100)
    /// What the device last received (written on the I/O thread).
    NATIVEBIND_READ(double, written, 0.0)

    NATIVEBIND_INVOKE void startPolling() {
        if (pollId_ == 0) pollId_ = io_.every(std::chrono::milliseconds(1), [this] { poll(); }, true);
    }
    NATIVEBIND_INVOKE void stopPolling() {
        io_.cancel(pollId_);
        pollId_ = 0;
    }

    Device() {
        // UI writes arrive on the nativebind thread; the bus is only touched on io_.
        setpoint.onWrite([this](double v) {
            io_.post([this, v] {
                deviceRegister_ = v;  // the "Modbus write"
                written = v;
            });
        });
    }

    std::atomic<int> onStopCalls{0};

protected:
    void onStop() override {
        ++onStopCalls;
        io_.stop();
    }

private:
    void poll() {
        ++n_;
        const auto v = static_cast<int32_t>(n_ % 100);
        nativebind::Batch group;  // Flutter sees a and b change together
        a = v;
        b = 100 - v;
        polls = n_;
    }

    int64_t n_ = 0;
    double deviceRegister_ = 0;
    uint64_t pollId_ = 0;
    nativebind::Worker io_{"device-io"};  // last: stops before the members above are destroyed
};
