// Run as its own process: the app returns from main without stopping
// nativebind (a desktop window closed), and onStop must still find what the
// app set up before starting alive. Exit status 0 = pass.

#include <cstdio>
#include <cstdlib>

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

int main() {
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
    return 0;  // no nativebind_stop(): the runtime stops itself at exit
}
