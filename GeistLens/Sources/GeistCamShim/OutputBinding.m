#import "OutputBinding.h"
#import "Session.h"
#import "Util.h"

const void *kGeistCamRecordingKey = &kGeistCamRecordingKey;
const void *kGeistCamSampleDelegateKey = &kGeistCamSampleDelegateKey;
const void *kGeistCamSampleQueueKey = &kGeistCamSampleQueueKey;

static OutputBinding s_outputBindings[GEISTCAM_MAX_OUTPUTS];
static int s_outputBindingCount = 0;
static dispatch_queue_t s_outputBindingsQueue;

void rebuildOutputBindingsForSession(AVCaptureSession *session) {
    if (!s_outputBindingsQueue) {
        s_outputBindingsQueue = dispatch_queue_create("geistcam.outputBindings", DISPATCH_QUEUE_SERIAL);
    }
    dispatch_sync(s_outputBindingsQueue, ^{
        int kept = 0;
        for (int i = 0; i < s_outputBindingCount; i++) {
            if (s_outputBindings[i].session != session) {
                if (kept != i) s_outputBindings[kept] = s_outputBindings[i];
                kept++;
            }
        }
        for (int i = kept; i < s_outputBindingCount; i++) {
            s_outputBindings[i] = (OutputBinding){0};
        }
        s_outputBindingCount = kept;

        // AVCaptureMovieFileOutput has both a video and an audio connection;
        // each one needs its own binding so the pacing loop dispatches video
        // frames and audio samples to the same output through different paths.
        for (id output in [session performSelector:@selector(outputs)]) {
            GeistCamSource *seenSources[GEISTCAM_MAX_SOURCES] = {0};
            int seenCount = 0;
            for (AVCaptureConnection *conn in [output connections]) {
                GeistCamSource *src = findSourceByUniqueID(firstDeviceUniqueIDInPorts(conn.inputPorts));
                if (!src) continue;
                BOOL already = NO;
                for (int k = 0; k < seenCount; k++) {
                    if (seenSources[k] == src) { already = YES; break; }
                }
                if (already) continue;
                if (seenCount < GEISTCAM_MAX_SOURCES) seenSources[seenCount++] = src;
                if (s_outputBindingCount >= GEISTCAM_MAX_OUTPUTS) break;
                s_outputBindings[s_outputBindingCount++] = (OutputBinding){
                    .output = output,
                    .source = src,
                    .session = session,
                };
                geistcam_markerf("bound output %s (%p) -> GeistCamSource[%d] '%s'",
                                  [NSStringFromClass([output class]) UTF8String],
                                  output, (int)src->kind, src->uniqueID.UTF8String);
            }
        }
    });
}

int snapshotOutputBindings(OutputBinding *outBuf) {
    if (!s_outputBindingsQueue) return 0;
    __block int n = 0;
    dispatch_sync(s_outputBindingsQueue, ^{
        n = s_outputBindingCount;
        for (int i = 0; i < n; i++) outBuf[i] = s_outputBindings[i];
    });
    return n;
}

BOOL isSourceActive(GeistCamSource *src) {
    if (isAppBackgrounded()) return NO;
    OutputBinding bindings[GEISTCAM_MAX_OUTPUTS];
    int n = snapshotOutputBindings(bindings);
    for (int i = 0; i < n; i++) {
        if (bindings[i].source != src) continue;
        if (isSessionRunning(bindings[i].session)) return YES;
    }
    NSArray<AVCaptureSession *> *running = snapshotRunningSessions();
    for (AVCaptureSession *sess in running) {
        for (AVCaptureInput *input in sess.inputs) {
            if (![input isKindOfClass:[AVCaptureDeviceInput class]]) continue;
            NSString *uid = ((AVCaptureDeviceInput *)input).device.uniqueID;
            if ([uid isEqualToString:src->uniqueID]) return YES;
        }
    }
    return NO;
}
