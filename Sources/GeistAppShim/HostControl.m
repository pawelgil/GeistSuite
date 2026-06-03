#import "HostControl.h"
#import "FakeIsCaptured.h"
#import "ControlSocket.h"
#import "ShimLog.h"

#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <pthread.h>
#include <stdatomic.h>
#include <unistd.h>
#include <errno.h>

static pthread_t gReaderThread;
static atomic_bool gReaderRunning = false;

void GC_SendUserPressedStart(BOOL micEnabled) {
    NSString *line = [NSString stringWithFormat:
        @"{\"type\":\"user_pressed_start\",\"micEnabled\":%@}\n",
        micEnabled ? @"true" : @"false"];
    GC_WriteControlLine(line);
}

void GC_SendUserCancelledStart(void) {
    GC_WriteControlLine(@"{\"type\":\"user_cancelled_start\"}\n");
}

void GC_SendUserPressedStop(void) {
    GC_WriteControlLine(@"{\"type\":\"user_pressed_stop\"}\n");
}

void GC_SendUserToggledMic(BOOL enabled) {
    NSString *line = [NSString stringWithFormat:
        @"{\"enabled\":%@,\"type\":\"user_toggled_mic\"}\n",
        enabled ? @"true" : @"false"];
    GC_WriteControlLine(line);
}

// Blocks briefly for the session's `state` reply so the local capture
// mirror is seeded before the picker can be tapped. Any bytes that
// arrive alongside the state envelope (incomplete trailing line, or a
// second batched line) stay in `carryOver` for the reader thread to
// pick up.
void GC_HandshakeHost(NSMutableData *carryOver) {
    GC_WriteControlLine(@"{\"type\":\"hello\",\"role\":\"host\"}\n");
    int fd = atomic_load(&gControlFD);
    if (fd < 0) return;

    // Bound the synchronous read so a missing daemon doesn't hang the
    // launching app. The reader thread that picks up afterwards will run
    // without a timeout.
    struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    NSDictionary *msg = GC_ReadControlMessage(carryOver);
    struct timeval none = { .tv_sec = 0, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &none, sizeof(none));

    if (!msg) {
        GC_LOG("no state reply from daemon (errno=%d) — assuming idle", errno);
        return;
    }
    if (![msg[@"type"] isEqual:@"state"]) {
        GC_LOG("handshake: ignoring %{public}@ before state", msg[@"type"]);
        return;
    }
    // macOSMicAuthorized defaults to YES if absent (older daemons or the
    // field hasn't been written yet) so we don't surface a false warning.
    BOOL micAuth = msg[@"macOSMicAuthorized"]
        ? [msg[@"macOSMicAuthorized"] boolValue] : YES;
    GC_SetMacOSMicAuthorized(micAuth);

    BOOL recording = [msg[@"recording"] boolValue];
    if (!recording) {
        GC_LOG("state reply recording=NO macOSMicAuthorized=%d", micAuth);
        GC_SetFakeCaptured(NO);
        GC_SetRecordingStartDate(nil);
        GC_SetMicEnabled(NO);
        return;
    }
    NSString *iso = msg[@"startedAt"];
    NSISO8601DateFormatter *fmt = [[NSISO8601DateFormatter alloc] init];
    GC_SetRecordingStartDate([fmt dateFromString:iso] ?: [NSDate date]);
    GC_SetMicEnabled([msg[@"micEnabled"] boolValue]);
    GC_SetFakeCaptured(YES);
    GC_LOG("state reply recording=YES startedAt=%{public}@ micEnabled=%d macOSMicAuthorized=%d",
           iso, [msg[@"micEnabled"] boolValue], micAuth);
    GC_PostScreenCapturedChange();
}

static void readMessages(NSMutableData *carryOver) {
    @autoreleasepool {
        while (atomic_load(&gReaderRunning)) {
            NSDictionary *msg = GC_ReadControlMessage(carryOver);
            if (!msg) {
                GC_LOG("host reader: connection closed");
                return;
            }
            NSString *type = msg[@"type"];
            if ([type isEqual:@"started"]) {
                NSString *iso = msg[@"startedAt"];
                NSISO8601DateFormatter *fmt = [[NSISO8601DateFormatter alloc] init];
                GC_SetRecordingStartDate([fmt dateFromString:iso] ?: [NSDate date]);
                GC_SetFakeCaptured(YES);
                GC_LOG("host reader: broadcast started");
                GC_PostScreenCapturedChange();
            } else if ([type isEqual:@"ended"]) {
                GC_SetFakeCaptured(NO);
                GC_SetRecordingStartDate(nil);
                GC_SetMicEnabled(NO);
                GC_LOG("host reader: broadcast ended");
                GC_PostScreenCapturedChange();
            } else if ([type isEqual:@"state"]) {
                // Runtime state push (e.g. macOS TCC mic auth changed).
                // The handshake handler covers the cold-start path; this
                // covers grant-while-broadcasting.
                BOOL micAuth = msg[@"macOSMicAuthorized"]
                    ? [msg[@"macOSMicAuthorized"] boolValue] : YES;
                GC_SetMacOSMicAuthorized(micAuth);
                GC_LOG("host reader: state push macOSMicAuthorized=%d", micAuth);
            }
        }
    }
}

// 1Hz poll — unobtrusive while still reconnecting within a second of
// the macOS app relaunching.
static void waitForHostAndConnect(NSMutableData *carryOver) {
    const char *path = GC_ControlSocketPath();
    while (atomic_load(&gReaderRunning)) {
        struct stat st;
        if (stat(path, &st) == 0 && GC_OpenControlConnection()) {
            GC_LOG("host reader: reconnected to %{public}s", path);
            GC_HandshakeHost(carryOver);
            return;
        }
        sleep(1);
    }
}

static void *readerMain(void *arg) {
    NSMutableData *carryOver = (__bridge_transfer NSMutableData *)arg;
    while (atomic_load(&gReaderRunning)) {
        if (atomic_load(&gControlFD) < 0) {
            // Fresh connection — start with a clean buffer.
            [carryOver setLength:0];
            waitForHostAndConnect(carryOver);
            if (!atomic_load(&gReaderRunning)) break;
        }
        int fd = atomic_load(&gControlFD);
        readMessages(carryOver);
        GC_CloseControlFDIfMatches(fd);
    }
    return NULL;
}

void GC_StartHostControlReader(NSMutableData *carryOver) {
    atomic_store(&gReaderRunning, true);
    pthread_create(&gReaderThread, NULL, readerMain,
                   (__bridge_retained void *)carryOver);
}
