#include "harness.hpp"

#include <cstring>
#include <exception>

namespace t {

std::vector<Case>& cases() {
    static std::vector<Case> all;
    return all;
}

void fail(const char* file, int line, const std::string& message) {
    const char* base = std::strrchr(file, '/');
    throw Failure{std::string(base ? base + 1 : file) + ":" + std::to_string(line) + ": " + message};
}

}  // namespace t

int main(int argc, char** argv) {
    const char* filter = argc > 1 ? argv[1] : nullptr;
    int passed = 0, failed = 0;
    for (const auto& c : t::cases()) {
        if (filter && !std::strstr(c.name, filter)) continue;
        try {
            c.fn();
            ++passed;
            std::printf("  ok    %s\n", c.name);
        } catch (const t::Failure& f) {
            ++failed;
            std::printf("  FAIL  %s\n        %s\n", c.name, f.message.c_str());
        } catch (const std::exception& e) {
            ++failed;
            std::printf("  FAIL  %s\n        exception: %s\n", c.name, e.what());
        }
        std::fflush(stdout);
    }
    std::printf("\n%d passed, %d failed\n", passed, failed);
    return failed == 0 ? 0 : 1;
}
