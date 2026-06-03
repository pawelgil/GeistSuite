#pragma once

#include <os/log.h>

// Each shim dylib defines its own `gc_log()` with a per-dylib subsystem
// (e.g. com.geistcast.shim.app vs .extension) so the unified-log viewer
// filters cleanly.
extern os_log_t gc_log(void);

// Appends a single line to `${GEISTCAST_LOG_DIR}/shim-{host,extension}.log`,
// where role is picked from the loaded bundle's identifier. If the env var
// is unset (e.g. shim loaded into a system daemon outside an injected
// session) the call is a no-op. The format string accepts `%{public}@` and
// `%{public}s` annotations like os_log; they're stripped before formatting.
// Call once after the shim establishes its control connection to the
// daemon. Until enabled, file appends are a no-op so the random system
// daemons that auto-load the shim via DYLD_INSERT_LIBRARIES don't
// pollute shim-{host,extension}.log.
extern void gc_file_log_enable(void);
extern void gc_file_log_append(const char *level, const char *fmt, ...);

#define GC_LOG(fmt, ...) do { \
    os_log(gc_log(), fmt, ##__VA_ARGS__); \
    gc_file_log_append("I", fmt, ##__VA_ARGS__); \
} while (0)

#define GC_ERR(fmt, ...) do { \
    os_log_error(gc_log(), fmt, ##__VA_ARGS__); \
    gc_file_log_append("E", fmt, ##__VA_ARGS__); \
} while (0)
