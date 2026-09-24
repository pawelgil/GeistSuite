#import "OutputBinding.h"
#import "Session.h"
#import "Util.h"

const void *kGeistCamRecordingKey = &kGeistCamRecordingKey;
const void *kGeistCamSampleDelegateKey = &kGeistCamSampleDelegateKey;
const void *kGeistCamSampleQueueKey = &kGeistCamSampleQueueKey;

@implementation GCOutputBinding
@end

static NSMutableArray<GCOutputBinding *> *s_outputBindings;
static dispatch_queue_t s_outputBindingsQueue;

static void ensureOutputBindings(void) {
    if (s_outputBindingsQueue) return;
    s_outputBindingsQueue = dispatch_queue_create("geistcam.outputBindings", DISPATCH_QUEUE_SERIAL);
    s_outputBindings = [NSMutableArray array];
}

void rebuildOutputBindingsForSession(AVCaptureSession *session) {
    if (isCameraSessionDeallocating(session)) return;
    ensureOutputBindings();
    dispatch_sync(s_outputBindingsQueue, ^{
        NSIndexSet *stale = [s_outputBindings indexesOfObjectsPassingTest:^BOOL(GCOutputBinding *binding, NSUInteger idx, BOOL *stop) {
            return binding.session == nil || binding.session == session;
        }];
        [s_outputBindings removeObjectsAtIndexes:stale];

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
                if (s_outputBindings.count >= GEISTCAM_MAX_OUTPUTS) break;
                GCOutputBinding *binding = [GCOutputBinding new];
                binding.output = output;
                binding.source = src;
                binding.session = session;
                binding.sessionID = cameraSessionIdentifier(session);
                [s_outputBindings addObject:binding];
                geistcam_markerf("bound output %s (%p) -> GeistCamSource[%d] '%s'",
                                  [NSStringFromClass([output class]) UTF8String],
                                  output, (int)src->kind, src->uniqueID.UTF8String);
            }
        }
    });
}

void removeOutputBindingsForSessionID(NSString *sessionID) {
    ensureOutputBindings();
    dispatch_sync(s_outputBindingsQueue, ^{
        NSIndexSet *matching = [s_outputBindings indexesOfObjectsPassingTest:^BOOL(GCOutputBinding *binding, NSUInteger idx, BOOL *stop) {
            return [binding.sessionID isEqualToString:sessionID];
        }];
        [s_outputBindings removeObjectsAtIndexes:matching];
    });
}

NSArray<GCOutputBinding *> *snapshotOutputBindings(void) {
    ensureOutputBindings();
    __block NSArray<GCOutputBinding *> *snapshot;
    dispatch_sync(s_outputBindingsQueue, ^{ snapshot = [s_outputBindings copy]; });
    return snapshot;
}

BOOL isSourceActive(GeistCamSource *src) {
    if (isAppBackgrounded()) return NO;
    for (GCOutputBinding *binding in snapshotOutputBindings()) {
        AVCaptureSession *session = binding.session;
        if (binding.source != src || !session) continue;
        if (isSessionDelivering(session)) return YES;
    }
    NSArray<AVCaptureSession *> *running = snapshotRunningSessions();
    for (AVCaptureSession *sess in running) {
        for (AVCaptureInput *input in sess.inputs) {
            if (![input isKindOfClass:[AVCaptureDeviceInput class]]) continue;
            NSString *uid = ((AVCaptureDeviceInput *)input).device.uniqueID;
            if ([uid isEqualToString:src->uniqueID] && isSessionDelivering(sess)) return YES;
        }
    }
    return NO;
}
