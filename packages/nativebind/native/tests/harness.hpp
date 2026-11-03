#pragma once
// Minimal test harness (no external dependencies).

#include <cstdio>
#include <ostream>
#include <sstream>
#include <string>
#include <type_traits>
#include <vector>

namespace t {

struct Case {
    const char* name;
    void (*fn)();
};

std::vector<Case>& cases();

struct Reg {
    Reg(const char* name, void (*fn)()) { cases().push_back({name, fn}); }
};

struct Failure {
    std::string message;
};

[[noreturn]] void fail(const char* file, int line, const std::string& message);

template <class T>
std::string show(const T& v) {
    if constexpr (std::is_enum_v<T>) {
        return std::to_string(static_cast<long long>(v));
    } else if constexpr (requires(std::ostream& o) { o << v; }) {
        std::ostringstream os;
        os << v;
        return os.str();
    } else {
        return "<value>";
    }
}

template <class A, class B>
void checkEq(const A& a, const B& b, const char* ea, const char* eb, const char* file, int line) {
    if (!(a == b)) fail(file, line, std::string(ea) + " == " + eb + "  (" + show(a) + " vs " + show(b) + ")");
}

}  // namespace t

#define TEST(name)                                     \
    static void name();                                \
    static const ::t::Reg reg_##name(#name, &name);   \
    static void name()

#define CHECK(expr)                                              \
    do {                                                         \
        if (!(expr)) ::t::fail(__FILE__, __LINE__, "CHECK(" #expr ")"); \
    } while (0)

#define CHECK_EQ(a, b) ::t::checkEq((a), (b), #a, #b, __FILE__, __LINE__)

#define CHECK_THROWS(expr, Type)                                                     \
    do {                                                                             \
        bool threw_ = false;                                                         \
        try {                                                                        \
            (void)(expr);                                                            \
        } catch (const Type&) {                                                      \
            threw_ = true;                                                           \
        }                                                                            \
        if (!threw_) ::t::fail(__FILE__, __LINE__, #expr " did not throw " #Type);   \
    } while (0)
