// A simulated media player: properties with ranges and validation, an enum,
// a list of structs, a signal, methods with arguments and results, and a timer.

#include <nativebind/nativebind.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

using namespace std::chrono_literals;

enum class PlayState {
    Stopped,
    Playing,
    Paused,
};

/// One entry of the play queue.
struct Track {
    int32_t id = 0;
    std::string title;
    std::string artist;
    std::chrono::seconds length{0};  ///< arrives in Dart as a Duration
    bool liked = false;

    bool operator==(const Track&) const = default;  // lets nativebind skip no-op updates
};

/// Plays the tracks in [queue]. The "decoder" is a timer that advances [position].
class Player : public nativebind::Module {
    NATIVEBIND_MODULE(Player)
public:
    /// Output volume, from 0 (muted) to 1.
    NATIVEBIND_PROP(double, volume, 0.5, .min = 0, .max = 1, .step = 0.05)
    /// Pick the next track at random.
    NATIVEBIND_PROP(bool, shuffle, false)
    NATIVEBIND_READ(PlayState, state, PlayState::Stopped)
    /// Title of the current track; empty when the queue is empty.
    NATIVEBIND_READ(std::string, title, "")
    /// Seconds into the current track.
    NATIVEBIND_READ(double, position, 0.0)
    NATIVEBIND_READ(double, duration, 0.0)
    NATIVEBIND_LIST(Track, queue)
    /// Sent with the new title whenever another track starts.
    NATIVEBIND_SIGNAL(trackChanged, std::string)

    NATIVEBIND_INVOKE void play() {
        if (queue.empty()) return;
        state = PlayState::Playing;
    }

    NATIVEBIND_INVOKE void pause() {
        if (state == PlayState::Playing) state = PlayState::Paused;
    }

    NATIVEBIND_INVOKE void next() {
        if (queue.empty()) return;
        const size_t n = queue.size();
        current_ = shuffle ? (current_ + 1 + seed_++ * 7) % n : (current_ + 1) % n;
        load(current_);
    }

    /// Jumps to [seconds] into the current track (clamped to its length).
    NATIVEBIND_INVOKE void seek(double seconds) { position = std::clamp(seconds, 0.0, double(duration)); }

    /// Appends a track and returns its id.
    NATIVEBIND_INVOKE int32_t add(std::string title, std::string artist, int32_t seconds) {
        const int32_t id = ++nextId_;
        queue.push_back(Track{id, std::move(title), std::move(artist), std::chrono::seconds(seconds)});
        if (queue.size() == 1) load(0);
        return id;
    }

    NATIVEBIND_INVOKE void toggleLike(int32_t id) {
        if (auto i = queue.findIndex([id](const Track& t) { return t.id == id; }))
            queue.update(*i, [](Track& t) { t.liked = !t.liked; });
    }

    NATIVEBIND_INVOKE void remove(int32_t id) {
        auto i = queue.findIndex([id](const Track& t) { return t.id == id; });
        if (!i) return;
        queue.erase(*i);
        if (queue.empty()) {
            nativebind::Batch batch;  // Flutter sees all four change together
            state = PlayState::Stopped;
            title = "";
            position = 0.0;
            duration = 0.0;
        } else if (*i == current_) {
            load(current_ % queue.size());
        } else if (*i < current_) {
            --current_;
        }
    }

    Player() {
        // UI writes pass through here first: snap the volume to 5 % steps.
        volume.validate([](double v) { return std::round(v * 20) / 20; });
        add("Morning Light", "The Examples", 184);
        add("Binding Agent", "FFI Quartet", 211);
        add("Zero Copy", "The Examples", 157);
    }

protected:
    void onStart() override {
        every(100ms, [this] { tick(); });
    }

private:
    void load(size_t i) {
        const Track t = queue.at(i);
        current_ = i;
        {
            nativebind::Batch batch;
            title = t.title;
            duration = double(t.length.count());
            position = 0.0;
        }
        trackChanged(t.title);
    }

    void tick() {
        if (state != PlayState::Playing) return;
        const double p = position + 0.1;
        if (p >= duration) next();
        else position = p;
    }

    size_t current_ = 0;
    size_t seed_ = 0;
    int32_t nextId_ = 0;
};
