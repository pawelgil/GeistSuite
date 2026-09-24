#import "Dispatch.h"
#import "Metadata.h"
#import "OutputBinding.h"
#import "Recording.h"
#import "Session.h"
#import "Source.h"
#import "Transform.h"
#import "Util.h"
#import "GeistWeakReference.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>

static AVCaptureConnection *firstVideoConnectionForOutput(id output) {
    for (AVCaptureConnection *c in [output connections]) {
        for (AVCaptureInputPort *p in c.inputPorts) {
            if ([p.mediaType isEqualToString:AVMediaTypeVideo]) return c;
        }
    }
    return nil;
}

void deliverToBoundOutputs(GeistCamSource *src, CMSampleBufferRef sb, CMTime originalSrcPTS) {
    if (!src) return;

    if (src->kind != GeistCamSourceKind_Audio) {
        CVPixelBufferRef newPB = CMSampleBufferGetImageBuffer(sb);
        CMFormatDescriptionRef newFD = CMSampleBufferGetFormatDescription(sb);
        if (newPB) CFRetain(newPB);
        if (newFD) CFRetain(newFD);
        CVPixelBufferRef oldPB = src->latestPixelBuffer;
        CMFormatDescriptionRef oldFD = src->latestFormatDescription;
        src->latestPixelBuffer = newPB;
        src->latestFormatDescription = newFD;
        if (oldPB) CFRelease(oldPB);
        if (oldFD) CFRelease(oldFD);
    }

    for (GCOutputBinding *binding in snapshotOutputBindings()) {
        AVCaptureSession *session = binding.session;
        id output = binding.output;
        if (binding.source != src || !session || !output) continue;
        if (!isSessionDelivering(session)) continue;
        uint64_t generation = sessionDeliveryGeneration(session);

        AVCaptureConnection *videoConn = (src->kind != GeistCamSourceKind_Audio)
            ? firstVideoConnectionForOutput(output) : nil;
        CMSampleBufferRef transformed = videoConn
            ? applyTransformToSampleBuffer(sb, transformParamsForConnection(videoConn))
            : NULL;
        CMSampleBufferRef toDeliver = transformed ?: sb;

        if ([output isKindOfClass:NSClassFromString(@"AVCaptureMovieFileOutput")]) {
            GeistCamMovieRecording *rec = objc_getAssociatedObject(output, kGeistCamRecordingKey);
            if (rec && rec.active && beginSessionDelivery(session, generation)) {
                appendToRecording(rec, src, toDeliver, originalSrcPTS);
                endSessionDelivery(session);
            }
        } else if ([output isKindOfClass:NSClassFromString(@"AVCaptureVideoDataOutput")] ||
                   [output isKindOfClass:NSClassFromString(@"AVCaptureAudioDataOutput")]) {
            GeistWeakReference *delegateReference = objc_getAssociatedObject(output, kGeistCamSampleDelegateKey);
            id delegate = delegateReference.object;
            dispatch_queue_t queue = objc_getAssociatedObject(output, kGeistCamSampleQueueKey);
            if (delegate && queue) {
                AVCaptureConnection *conn = videoConn ?: [[output connections] firstObject];
                CFRetain(toDeliver);
                CMSampleBufferRef sbRetained = toDeliver;
                __weak id weakDelegate = delegate;
                __weak AVCaptureSession *weakSession = session;
                __weak id weakOutput = output;
                __weak AVCaptureConnection *weakConnection = conn;
                dispatch_async(queue, ^{
                    AVCaptureSession *liveSession = weakSession;
                    id liveOutput = weakOutput;
                    AVCaptureConnection *liveConnection = weakConnection;
                    id liveDelegate = weakDelegate;
                    if (!liveSession || !liveOutput || !liveConnection ||
                        !beginSessionDelivery(liveSession, generation)) {
                        CFRelease(sbRetained);
                        return;
                    }
                    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
                    if ([liveDelegate respondsToSelector:sel]) {
                        void (*fn)(id, SEL, id, CMSampleBufferRef, AVCaptureConnection *) = (void *)objc_msgSend;
                        fn(liveDelegate, sel, liveOutput, sbRetained, liveConnection);
                    }
                    endSessionDelivery(liveSession);
                    CFRelease(sbRetained);
                });
            }
        }
        // AVCapturePhotoOutput consumes via on-demand snapshot — no per-frame work.

        if (transformed) CFRelease(transformed);
    }

    if (src->kind != GeistCamSourceKind_Audio) {
        metadataDispatchVideoFrame(sb, src);
    }
}
