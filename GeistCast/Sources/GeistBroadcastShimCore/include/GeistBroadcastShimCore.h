#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Wire frame header magic, little-endian 'GCST'. Both the host (Swift) and
// the simulator-side shim (Obj-C) verify against this exact value; the
// authoritative definition lives here so neither side can drift.
#define GEISTCAST_WIRE_MAGIC 0x54534347u

#ifdef __cplusplus
extern "C" {
#endif

int32_t geistbroadcast_encode_event_line(
    const char *type,
    const char *simulator_udid,
    const char *host_app_bundle_id,
    const char *extension_bundle_id,
    const char *started_at_iso8601,
    char *buffer,
    size_t buffer_len);

bool geistbroadcast_should_log_progress(
    double now,
    double interval,
    double *last_log_time);

#ifdef __cplusplus
}
#endif
