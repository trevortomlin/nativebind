// Downloads: an instanced module (one object per transfer), each with its own
// worker thread doing "blocking" I/O, and a singleton that creates them.

#include <nativebind/nativebind.hpp>

#include <atomic>
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <string>
#include <thread>

using namespace std::chrono_literals;

enum class DownloadState {
    Running,
    Paused,
    Done,
};

/// One transfer. Dart sees every live one in `Download.instances`.
class Download : public nativebind::Module {
    NATIVEBIND_MODULE(Download, .instanced = true)
public:
    NATIVEBIND_READ(std::string, name, "")
    NATIVEBIND_READ(DownloadState, state, DownloadState::Running)
    NATIVEBIND_READ(int64_t, received, 0)
    NATIVEBIND_READ(int64_t, total, 0)
    /// From 0 to 1.
    NATIVEBIND_READ(double, progress, 0.0)
    /// Simulated link speed.
    NATIVEBIND_PROP(int32_t, speed, 512, .min = 64, .max = 4096, .step = 64, .label = "Speed limit",
                    .attrs = {{"unit", "KiB/s"}})
    /// Sent once, when the last byte arrived.
    NATIVEBIND_SIGNAL(finished)

    NATIVEBIND_INVOKE void pause() {
        if (state != DownloadState::Running) return;
        paused_ = true;
        state = DownloadState::Paused;
    }

    NATIVEBIND_INVOKE void resume() {
        if (state != DownloadState::Paused) return;
        paused_ = false;
        state = DownloadState::Running;
    }

    // nativebind::spawn<Download>(key, name, bytes) forwards these arguments.
    Download(std::string fileName, int64_t bytes) {
        name = std::move(fileName);
        total = bytes;
    }

protected:
    void onStart() override { io_.every(100ms, [this] { transfer(); }); }
    void onStop() override { io_.stop(); }

private:
    // Runs on io_, never on the nativebind thread, so blocking here is fine.
    void transfer() {
        if (paused_ || state == DownloadState::Done) return;
        std::this_thread::sleep_for(20ms);  // stands in for a blocking socket read
        const int64_t chunk = int64_t(speed) * 1024 / 10;
        const int64_t got = std::min<int64_t>(received + chunk, total);
        const bool done = got == total;
        {
            nativebind::Batch batch;  // received, progress and state arrive together
            received = got;
            progress = total > 0 ? double(got) / double(total) : 1.0;
            if (done) state = DownloadState::Done;
        }
        if (done) finished();
    }

    std::atomic<bool> paused_{false};
    nativebind::Worker io_{"download"};  // declared last: stops before the members above go away
};

/// Starts and removes downloads.
class Downloads : public nativebind::Module {
    NATIVEBIND_MODULE(Downloads)
public:
    /// Downloads that are not done yet.
    NATIVEBIND_READ(int32_t, active, 0)

    /// Starts downloading [bytes] bytes as [name]; returns the new download's key.
    NATIVEBIND_INVOKE int32_t start(std::string name, int64_t bytes) {
        const int32_t key = ++nextKey_;
        Download& d = nativebind::spawn<Download>(key, std::move(name), bytes);
        // finished is emitted on the download's worker thread: hop over to ours.
        // Owned by *this, so the connection ends if Downloads goes first.
        d.finished.connect(*this, [this] { post([this] { recount(); }); });
        active = active + 1;
        return key;
    }

    NATIVEBIND_INVOKE void remove(int32_t key) {
        for (Download* d : nativebind::instances<Download>())
            if (d->key() == uint64_t(key)) {
                if (d->state != DownloadState::Done) active = active - 1;
                nativebind::destroy(*d);
            }
    }

    NATIVEBIND_INVOKE void clearFinished() {
        for (Download* d : nativebind::instances<Download>())
            if (d->state == DownloadState::Done) nativebind::destroy(*d);
    }

private:
    void recount() {
        int32_t n = 0;
        for (Download* d : nativebind::instances<Download>())
            if (d->state != DownloadState::Done) ++n;
        active = n;
    }

    int32_t nextKey_ = 0;
};
