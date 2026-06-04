#import "RecordingState.h"
#import "Server.h"
#import "Util.h"
#import "Wire.h"
#import <AVFoundation/AVFoundation.h>
#import <pthread.h>

static NSHashTable *s_activeMovieRecordings;
static NSHashTable<AVAssetWriter *> *s_flaggedWriters;
static BOOL s_lastReportedActive = NO;
static pthread_mutex_t s_stateMutex = PTHREAD_MUTEX_INITIALIZER;

static void ensureInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s_activeMovieRecordings = [NSHashTable hashTableWithOptions:NSHashTableWeakMemory];
        s_flaggedWriters = [NSHashTable hashTableWithOptions:NSHashTableWeakMemory];
    });
}

static void sendCurrentState(BOOL active) {
    GeistCamRecordingStateMsg msg = { active ? 1u : 0u };
    serverWriteMessage(GEISTCAM_MSG_RECORDING_STATE, &msg, sizeof(msg));
    geistcam_markerf("recordingState: → %s", active ? "ACTIVE" : "idle");
}

// Caller must hold s_stateMutex. Returns the (possibly unchanged) current state.
static BOOL recomputeAndNotifyLocked(void) {
    BOOL active = (s_activeMovieRecordings.count > 0 || s_flaggedWriters.count > 0);
    BOOL changed = (active != s_lastReportedActive);
    s_lastReportedActive = active;
    if (changed) {
        // Send while holding the lock — keeps state and wire signal in lockstep
        // even if many transitions happen in rapid succession.
        sendCurrentState(active);
    }
    return active;
}

void recordingMovieOutputStarted(GeistCamMovieRecording *rec) {
    ensureInit();
    if (!rec) return;
    pthread_mutex_lock(&s_stateMutex);
    [s_activeMovieRecordings addObject:rec];
    recomputeAndNotifyLocked();
    pthread_mutex_unlock(&s_stateMutex);
}

void recordingMovieOutputStopped(GeistCamMovieRecording *rec) {
    ensureInit();
    if (!rec) return;
    pthread_mutex_lock(&s_stateMutex);
    [s_activeMovieRecordings removeObject:rec];
    recomputeAndNotifyLocked();
    pthread_mutex_unlock(&s_stateMutex);
}

void recordingAssetWriterFlagged(AVAssetWriter *writer) {
    ensureInit();
    if (!writer) return;
    pthread_mutex_lock(&s_stateMutex);
    [s_flaggedWriters addObject:writer];
    recomputeAndNotifyLocked();
    pthread_mutex_unlock(&s_stateMutex);
}

void recordingAssetWriterTerminated(AVAssetWriter *writer) {
    ensureInit();
    if (!writer) return;
    pthread_mutex_lock(&s_stateMutex);
    [s_flaggedWriters removeObject:writer];
    recomputeAndNotifyLocked();
    pthread_mutex_unlock(&s_stateMutex);
}

BOOL recordingIsActive(void) {
    ensureInit();
    pthread_mutex_lock(&s_stateMutex);
    BOOL state = s_lastReportedActive;
    pthread_mutex_unlock(&s_stateMutex);
    return state;
}

void recordingResyncForNewFeeder(void) {
    ensureInit();
    pthread_mutex_lock(&s_stateMutex);
    BOOL state = s_lastReportedActive;
    pthread_mutex_unlock(&s_stateMutex);
    sendCurrentState(state);
}
