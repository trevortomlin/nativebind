// Run as its own process: the app returns from main without stopping
// nativebind (a desktop window closed), and onStop must still find what the
// app set up before starting alive. With "from-task", exit() is called from
// a task on the nativebind thread and the process must still exit cleanly.
// Exit status 0 = pass.

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>

#include "modules/thermo.cpp"  // class definitions only (all inline), safe to include
#include "nativebind/nativebind.h"

namespace {

// Stands for any app object with a destructor: a logger, a settings store, a
// device handle. Constructed in main, before nativebind starts.
struct AppState {
    bool alive = true;
    ~AppState() { alive = false; }
};

AppState& appState() {
    static AppState s;
    return s;
}

}  // namespace

int main(int argc, char** argv) {
    appState();
    if (nativebind_start() != NATIVEBIND_OK) return 2;
    nativebind::spawn<Zone>(1, "z");
    Zone::stopHook = [] {
        if (!appState().alive) {
            std::fputs("exit_check: onStop ran after the app's objects were destroyed\n", stderr);
            std::_Exit(1);
        }
        std::fputs("exit_check: onStop ran before the app's objects were destroyed\n", stderr);
    };
    if (argc > 1 && std::strcmp(argv[1], "from-task") == 0) {
        static std::atomic<bool> posted{false};
        nativebind::post([] {
            while (!posted.load()) std::this_thread::yield();  // main is out of post()
            std::exit(0);
        });
        posted = true;
        std::this_thread::sleep_for(std::chrono::seconds(10));
        return 4;  // exit() never happened
    }
    return 0;  // no nativebind_stop(): the runtime stops itself at exit
}
