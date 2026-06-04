#include "GeistBroadcastShimCore.h"
#include <stdio.h>

int32_t geistbroadcast_encode_event_line(
    const char *type,
    const char *simulator_udid,
    const char *host_app_bundle_id,
    const char *extension_bundle_id,
    const char *started_at_iso8601,
    char *buffer,
    size_t buffer_len)
{
    int n = snprintf(buffer, buffer_len,
        "{\"type\":\"%s\","
        "\"simulatorUDID\":\"%s\","
        "\"hostAppBundleID\":\"%s\","
        "\"extensionBundleID\":\"%s\","
        "\"startedAt\":\"%s\"}",
        type, simulator_udid, host_app_bundle_id, extension_bundle_id, started_at_iso8601);

    if (n < 0 || (size_t)n >= buffer_len) {
        return -1;
    }
    return (int32_t)n;
}
