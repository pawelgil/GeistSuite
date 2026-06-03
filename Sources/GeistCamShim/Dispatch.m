#import "Dispatch.h"
#import "Metadata.h"
#import "OutputBinding.h"
#import "Recording.h"
#import "Session.h"
#import "Source.h"
#import "Transform.h"
#import "Util.h"
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

    OutputBinding bindings[GEISTCAM_MAX_OUTPUTS];
    int n = snapshotOutputBindings(bindings);
    for (int i = 0; i < n; i++) {
        if (bindings[i].source != src) continue;
        if (!isSessionRunning(bindings[i].session)) continue;
        id output = bindings[i].output;
        if (!output) continue;

        AVCaptureConnection *videoConn = (src->kind != GeistCamSourceKind_Audio)
            ? firstVideoConnectionForOutput(output) : nil;
        CMSampleBufferRef transformed = videoConn
            ? applyTransformToSampleBuffer(sb, transformParamsForConnection(videoConn))
            : NULL;
        CMSampleBufferRef toDeliver = transformed ?: sb;

        if ([output isKindOfClass:NSClassFromString(@"AVCaptureMovieFileOutput")]) {
            GeistCamMovieRecording *rec = objc_getAssociatedObject(output, kGeistCamRecordingKey);
            if (rec && rec.active) appendToRecording(rec, src, toDeliver, originalSrcPTS);
        } else if ([output isKindOfClass:NSClassFromString(@"AVCaptureVideoDataOutput")] ||
                   [output isKindOfClass:NSClassFromString(@"AVCaptureAudioDataOutput")]) {
            id delegate = objc_getAssociatedObject(output, kGeistCamSampleDelegateKey);
            dispatch_queue_t queue = objc_getAssociatedObject(output, kGeistCamSampleQueueKey);
            if (delegate && queue) {
                AVCaptureConnection *conn = videoConn ?: [[output connections] firstObject];
                CFRetain(toDeliver);
                CMSampleBufferRef sbRetained = toDeliver;
                id delegateRetained = delegate;
                id outputRetained = output;
                dispatch_async(queue, ^{
                    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
                    if ([delegateRetained respondsToSelector:sel]) {
                        void (*fn)(id, SEL, id, CMSampleBufferRef, AVCaptureConnection *) = (void *)objc_msgSend;
                        fn(delegateRetained, sel, outputRetained, sbRetained, conn);
                    }
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
