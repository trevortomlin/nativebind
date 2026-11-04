/*
 * nativebind C ABI. This is the only surface Dart talks to; it is the same for
 * every application (modules are addressed by type name, instance handle and
 * member index). See doc/wire-format.md for the byte formats.
 *
 * Threading: nativebind_drain and nativebind_request_resync must be called by a
 * single consumer thread (the Dart UI isolate). Everything else is
 * thread-safe.
 */
#ifndef NATIVEBIND_H
#define NATIVEBIND_H

#include <stdint.h>

#if defined(_WIN32)
#define NATIVEBIND_API __declspec(dllexport)
#else
#define NATIVEBIND_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define NATIVEBIND_ABI_VERSION 2

/* Status codes. */
enum {
    NATIVEBIND_OK = 0,
    NATIVEBIND_E_NOT_STARTED = -1,
    NATIVEBIND_E_NO_INSTANCE = -2,  /* instance handle unknown or destroyed */
    NATIVEBIND_E_NO_MEMBER = -3,    /* property or method index out of range */
    NATIVEBIND_E_TYPE = -4,         /* value/arguments do not match the C++ types */
    NATIVEBIND_E_READ_ONLY = -5,
    NATIVEBIND_E_DISABLED = -6,
    NATIVEBIND_E_ACCESS = -7,       /* refused by the guard */
    NATIVEBIND_E_EXCEPTION = -8,    /* the C++ method threw */
    NATIVEBIND_E_UNKNOWN_TYPE = -9, /* module type name not registered */
    NATIVEBIND_E_TIMEOUT = -10,
    NATIVEBIND_E_INTERNAL = -11
};

NATIVEBIND_API int32_t nativebind_abi_version(void);

/* Pass NativeApi.initializeApiDLData. Returns 0 on success. */
NATIVEBIND_API intptr_t nativebind_init_dart_api(void* data);

/* Starts the runtime (idempotent): creates singletons, calls onStart. */
NATIVEBIND_API int32_t nativebind_start(void);
NATIVEBIND_API void nativebind_stop(void);

/* Registers the consumer to wake when changes are pending: a Dart native port
 * (an integer is posted), or a C callback for native hosts. Either call drops
 * queued results and requests a full resync, so a restarted isolate starts
 * from a clean state. Pass 0 / NULL to detach. */
NATIVEBIND_API void nativebind_attach_port(int64_t port);
NATIVEBIND_API void nativebind_attach_callback(void (*wake)(void* user), void* user);

/* Returns pending change records; *out_len receives the byte count. The
 * buffer stays valid until the next nativebind_drain call. */
NATIVEBIND_API const uint8_t* nativebind_drain(uint32_t* out_len);
/* The next drain returns the complete state (after a detected gap). */
NATIVEBIND_API void nativebind_request_resync(void);

/* Module types. Ids are only valid within this process. */
NATIVEBIND_API int32_t nativebind_type_count(void);
NATIVEBIND_API int32_t nativebind_type_id(const char* name); /* id, or NATIVEBIND_E_UNKNOWN_TYPE */
NATIVEBIND_API const char* nativebind_type_name(int32_t id);
NATIVEBIND_API const char* nativebind_type_schema(int32_t id);

/* Writes a property from the UI. `value` is one encoded value; `seq` is
 * echoed back in the next Prop record of that property once the write was
 * processed (accepted or rejected). `value` may be null only when `len` is
 * 0; otherwise the call returns NATIVEBIND_E_TYPE. */
NATIVEBIND_API int32_t nativebind_write(uint32_t instance, uint16_t prop, const uint8_t* value, uint32_t len, uint32_t seq);

/* Calls a method asynchronously. `args` is the encoded arguments in order.
 * The outcome arrives as a Result record carrying `call_id`. `args` may be
 * null only when `len` is 0; otherwise the call returns NATIVEBIND_E_TYPE. */
NATIVEBIND_API int32_t nativebind_invoke(uint32_t instance, uint16_t method, const uint8_t* args, uint32_t len,
                                 uint32_t call_id);

/* Waits until work queued on the nativebind thread has run (tests). */
NATIVEBIND_API int32_t nativebind_flush(int32_t timeout_ms);

/* Message for the last error on this thread, or "". */
NATIVEBIND_API const char* nativebind_last_error(void);
NATIVEBIND_API const char* nativebind_status_message(int32_t status);

#ifdef __cplusplus
}
#endif

#endif /* NATIVEBIND_H */
