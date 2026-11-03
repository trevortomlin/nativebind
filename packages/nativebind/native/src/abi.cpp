// The C ABI (nativebind.h). Every entry point catches all exceptions: nothing may
// unwind into Dart.

#include "nativebind/nativebind.h"

#include <exception>

#include "runtime.hpp"

#if NATIVEBIND_WITH_DART
#include "dart_api_dl.h"
#endif

using nativebind::detail::Runtime;
using nativebind::detail::setLastError;

namespace {

template <class F>
int32_t guarded(F&& f) noexcept {
    try {
        return f();
    } catch (const std::exception& e) {
        setLastError(e.what());
    } catch (...) {
        setLastError("unknown exception");
    }
    return NATIVEBIND_E_INTERNAL;
}

}  // namespace

extern "C" {

NATIVEBIND_API int32_t nativebind_abi_version(void) { return NATIVEBIND_ABI_VERSION; }

NATIVEBIND_API intptr_t nativebind_init_dart_api(void* data) {
#if NATIVEBIND_WITH_DART
    return Dart_InitializeApiDL(data);
#else
    (void)data;
    setLastError("nativebind was built without Dart support (NATIVEBIND_WITH_DART=0)");
    return -1;
#endif
}

NATIVEBIND_API int32_t nativebind_start(void) {
    return guarded([] {
        Runtime::get().start();
        return NATIVEBIND_OK;
    });
}

NATIVEBIND_API void nativebind_stop(void) {
    guarded([] {
        Runtime::get().stop();
        return NATIVEBIND_OK;
    });
}

NATIVEBIND_API void nativebind_attach_port(int64_t port) {
    guarded([port] {
        Runtime::get().attachPort(port);
        return NATIVEBIND_OK;
    });
}

NATIVEBIND_API void nativebind_attach_callback(void (*wake)(void*), void* user) {
    guarded([wake, user] {
        Runtime::get().attachCallback(wake, user);
        return NATIVEBIND_OK;
    });
}

NATIVEBIND_API const uint8_t* nativebind_drain(uint32_t* out_len) {
    try {
        const auto& buf = Runtime::get().drain();
        if (out_len) *out_len = static_cast<uint32_t>(buf.size());
        return buf.data();
    } catch (const std::exception& e) {
        setLastError(e.what());
    } catch (...) {
        setLastError("unknown exception");
    }
    // Something failed half-way; make the consumer start over.
    Runtime::get().requestResync();
    if (out_len) *out_len = 0;
    return nullptr;
}

NATIVEBIND_API void nativebind_request_resync(void) { Runtime::get().requestResync(); }

NATIVEBIND_API int32_t nativebind_type_count(void) { return Runtime::get().typeCount(); }

NATIVEBIND_API int32_t nativebind_type_id(const char* name) {
    if (!name) return NATIVEBIND_E_UNKNOWN_TYPE;
    return Runtime::get().typeId(name);
}

NATIVEBIND_API const char* nativebind_type_name(int32_t id) {
    const auto* t = Runtime::get().type(id);
    return t ? t->name : nullptr;
}

NATIVEBIND_API const char* nativebind_type_schema(int32_t id) {
    const auto* t = Runtime::get().type(id);
    return t ? t->schema : nullptr;
}

NATIVEBIND_API int32_t nativebind_write(uint32_t instance, uint16_t prop, const uint8_t* value, uint32_t len, uint32_t seq) {
    return guarded([&] { return Runtime::get().write(instance, prop, value, len, seq); });
}

NATIVEBIND_API int32_t nativebind_invoke(uint32_t instance, uint16_t method, const uint8_t* args, uint32_t len,
                                 uint32_t call_id) {
    return guarded([&] { return Runtime::get().invoke(instance, method, args, len, call_id); });
}

NATIVEBIND_API int32_t nativebind_flush(int32_t timeout_ms) {
    return guarded([timeout_ms] {
        return Runtime::get().flush(std::chrono::milliseconds(timeout_ms)) ? NATIVEBIND_OK : NATIVEBIND_E_TIMEOUT;
    });
}

NATIVEBIND_API const char* nativebind_last_error(void) { return nativebind::detail::lastError(); }

NATIVEBIND_API const char* nativebind_status_message(int32_t status) {
    switch (status) {
        case NATIVEBIND_OK: return "ok";
        case NATIVEBIND_E_NOT_STARTED: return "nativebind is not started";
        case NATIVEBIND_E_NO_INSTANCE: return "no such instance";
        case NATIVEBIND_E_NO_MEMBER: return "no such member";
        case NATIVEBIND_E_TYPE: return "type mismatch";
        case NATIVEBIND_E_READ_ONLY: return "read-only";
        case NATIVEBIND_E_DISABLED: return "disabled";
        case NATIVEBIND_E_ACCESS: return "access denied";
        case NATIVEBIND_E_EXCEPTION: return "method threw an exception";
        case NATIVEBIND_E_UNKNOWN_TYPE: return "unknown module type";
        case NATIVEBIND_E_TIMEOUT: return "timeout";
        case NATIVEBIND_E_INTERNAL: return "internal error";
    }
    return "unknown status";
}

}  // extern "C"
