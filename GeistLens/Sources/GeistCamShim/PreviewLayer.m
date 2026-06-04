#import "PreviewLayer.h"
#import "Session.h"
#import "Source.h"
#import "Transform.h"
#import "Util.h"
#import <objc/runtime.h>
#import <stdatomic.h>

static _Atomic int64_t s_pvEnqueued = 0;
static _Atomic int64_t s_pvSkippedNotReady = 0;

static void logPreviewStatsIfDue(int64_t enq) {
    if (enq == 0 || enq % 500 != 0) return;
    geistcam_markerf("preview: enqueued=%lld skippedNotReady=%lld",
                     enq, atomic_load(&s_pvSkippedNotReady));
}

@interface AVCaptureVideoPreviewLayer (GeistCamPrivate)
- (AVCaptureSession *)session;
@end

// AVSampleBufferDisplayLayer drops frames whose PTS goes backwards relative to
// the previously enqueued one. Source PTS is now end-to-end from the lib
// (needed for A/V sync at AVAssetWriter), but source-switches and file-loop
// wraparounds can still produce backwards PTS at the display. Restamp with a
// monotonic host-clock PTS here so the display path is decoupled.
static CMSampleBufferRef geistcam_restampForDisplay(CMSampleBufferRef sb) {
    if (!sb) return NULL;
    CMSampleTimingInfo timing = {0};
    CMSampleBufferGetSampleTimingInfo(sb, 0, &timing);
    timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock());
    timing.decodeTimeStamp = kCMTimeInvalid;
    CMSampleBufferRef out = NULL;
    OSStatus s = CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, sb, 1, &timing, &out);
    if (s != noErr) return NULL;
    return out;
}

static const void *kGeistCamDisplayLayerKey = &kGeistCamDisplayLayerKey;
static const void *kGeistCamDisplayFormatKey = &kGeistCamDisplayFormatKey;
static NSHashTable *s_previewLayers;
static NSMapTable *s_previewBinding;

typedef struct { int32_t w, h; uint32_t fmt; } GeistCamDisplayFormat;

static AVSampleBufferDisplayLayer *getOrCreateDisplaySublayer(AVCaptureVideoPreviewLayer *layer) {
    AVSampleBufferDisplayLayer *display = objc_getAssociatedObject(layer, kGeistCamDisplayLayerKey);
    if (display) return display;
    display = [[AVSampleBufferDisplayLayer alloc] init];
    display.videoGravity = layer.videoGravity ?: AVLayerVideoGravityResizeAspect;
    display.frame = layer.bounds;
    [layer addSublayer:display];
    objc_setAssociatedObject(layer, kGeistCamDisplayLayerKey, display, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @synchronized (s_previewLayers) { [s_previewLayers addObject:layer]; }
    geistcam_markerf("registered PreviewLayer=%p (display sublayer=%p)", layer, display);
    return display;
}

static GeistCamSource *bindingForPreviewLayer(AVCaptureVideoPreviewLayer *layer) {
    @synchronized (s_previewBinding) {
        NSValue *v = [s_previewBinding objectForKey:layer];
        if (v) return (GeistCamSource *)[v pointerValue];
    }
    // Prefer the layer's own connection (more reliable than session.inputs
    // during a back/front flip — both inputs may be momentarily attached).
    GeistCamSource *found = findSourceByUniqueID(firstDeviceUniqueIDInPorts(layer.connection.inputPorts));
    if (!found || found->kind == GeistCamSourceKind_Audio) {
        found = NULL;
        for (AVCaptureInput *input in layer.session.inputs) {
            if (![input isKindOfClass:[AVCaptureDeviceInput class]]) continue;
            GeistCamSource *s = findSourceByUniqueID(((AVCaptureDeviceInput *)input).device.uniqueID);
            if (s && s->kind != GeistCamSourceKind_Audio) { found = s; break; }
        }
    }
    if (found) {
        @synchronized (s_previewBinding) {
            [s_previewBinding setObject:[NSValue valueWithPointer:found] forKey:layer];
        }
    }
    return found;
}

void invalidatePreviewBindings(void) {
    @synchronized (s_previewBinding) { [s_previewBinding removeAllObjects]; }
}

static IMP s_origPLSetSession;
static void swiz_pl_setSession(id self, SEL _cmd, id session) {
    if (s_origPLSetSession) ((void (*)(id, SEL, id))s_origPLSetSession)(self, _cmd, session);
    if (session) (void)getOrCreateDisplaySublayer((AVCaptureVideoPreviewLayer *)self);
    invalidatePreviewBindings();
}

static IMP s_origPLLayoutSublayers;
static void swiz_pl_layoutSublayers(id self, SEL _cmd) {
    if (s_origPLLayoutSublayers) ((void (*)(id, SEL))s_origPLLayoutSublayers)(self, _cmd);
    AVSampleBufferDisplayLayer *display = objc_getAssociatedObject(self, kGeistCamDisplayLayerKey);
    if (display) display.frame = ((CALayer *)self).bounds;
}

static IMP s_origPLSetVideoGravity;
static void swiz_pl_setVideoGravity(id self, SEL _cmd, NSString *gravity) {
    if (s_origPLSetVideoGravity) ((void (*)(id, SEL, NSString *))s_origPLSetVideoGravity)(self, _cmd, gravity);
    AVSampleBufferDisplayLayer *display = objc_getAssociatedObject(self, kGeistCamDisplayLayerKey);
    if (display && gravity) display.videoGravity = gravity;
}

void installPreviewSwizzles(void) {
    if (!s_previewLayers)  s_previewLayers  = [NSHashTable weakObjectsHashTable];
    if (!s_previewBinding) s_previewBinding = [NSMapTable weakToStrongObjectsMapTable];
    swizzleMethod(@"AVCaptureVideoPreviewLayer", @selector(setSession:),
                  (IMP)swiz_pl_setSession, &s_origPLSetSession);
    swizzleMethod(@"AVCaptureVideoPreviewLayer", @selector(layoutSublayers),
                  (IMP)swiz_pl_layoutSublayers, &s_origPLLayoutSublayers);
    swizzleMethod(@"AVCaptureVideoPreviewLayer", @selector(setVideoGravity:),
                  (IMP)swiz_pl_setVideoGravity, &s_origPLSetVideoGravity);
}

void deliverFrameToPreviewLayers(CMSampleBufferRef sb, GeistCamSource *src) {
    NSArray *layers;
    @synchronized (s_previewLayers) { layers = [[s_previewLayers allObjects] copy]; }
    for (AVCaptureVideoPreviewLayer *layer in layers) {
        if (bindingForPreviewLayer(layer) != src) continue;
        AVCaptureSession *sess = layer.session;
        if (!isSessionRunning(sess)) continue;
        AVSampleBufferDisplayLayer *display = objc_getAssociatedObject(layer, kGeistCamDisplayLayerKey);
        if (!display) continue;
        if (!display.sampleBufferRenderer.isReadyForMoreMediaData) {
            int64_t s = atomic_fetch_add(&s_pvSkippedNotReady, 1) + 1;
            if (s % 100 == 0) {
                geistcam_markerf("preview: renderer not ready display=%p skips=%lld", display, s);
            }
            continue;
        }
        // Each preview layer has its own connection with independent rotation/
        // mirror state — front-camera previews are typically auto-mirrored.
        TransformParams params = transformParamsForConnection(layer.connection);
        CMSampleBufferRef transformed = applyTransformToSampleBuffer(sb, params);
        CMSampleBufferRef toEnqueue = transformed ?: sb;

        // AVSampleBufferDisplayLayer freezes on mid-stream format change.
        // Track last format; on change, flush then enqueue via the
        // completion handler — flushWithRemovalOfDisplayedImage is async,
        // so a same-tick enqueue races the in-flight flush and leaves the
        // layer stuck on the prior frame.
        CMFormatDescriptionRef fdesc = CMSampleBufferGetFormatDescription(toEnqueue);
        BOOL needsFlush = NO;
        if (fdesc) {
            CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(fdesc);
            uint32_t pf = CMFormatDescriptionGetMediaSubType(fdesc);
            NSValue *lastVal = objc_getAssociatedObject(display, kGeistCamDisplayFormatKey);
            GeistCamDisplayFormat last = {0};
            if (lastVal) [lastVal getValue:&last];
            BOOL hadPrevious = (last.w != 0 || last.h != 0 || last.fmt != 0);
            BOOL changed = (last.w != dims.width || last.h != dims.height || last.fmt != pf);
            needsFlush = hadPrevious && changed;
            if (changed) {
                geistcam_markerf("preview: format change display=%p %dx%d→%dx%d pixfmt=0x%08x flush=%d",
                                 display, last.w, last.h, dims.width, dims.height, pf, needsFlush);
                GeistCamDisplayFormat fmt = { dims.width, dims.height, pf };
                NSValue *val = [NSValue valueWithBytes:&fmt objCType:@encode(GeistCamDisplayFormat)];
                objc_setAssociatedObject(display, kGeistCamDisplayFormatKey, val,
                                          OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }

        CMSampleBufferRef restamped = geistcam_restampForDisplay(toEnqueue);
        CMSampleBufferRef forDisplay = restamped ?: toEnqueue;
        if (needsFlush) {
            CFRetain(forDisplay);
            geistcam_markerf("preview: flush requested display=%p", display);
            [display.sampleBufferRenderer flushWithRemovalOfDisplayedImage:YES
                                                        completionHandler:^{
                geistcam_markerf("preview: flush completed display=%p ready=%d", display,
                                 display.sampleBufferRenderer.isReadyForMoreMediaData);
                [display.sampleBufferRenderer enqueueSampleBuffer:forDisplay];
                CFRelease(forDisplay);
                int64_t e = atomic_fetch_add(&s_pvEnqueued, 1) + 1;
                logPreviewStatsIfDue(e);
            }];
        } else {
            [display.sampleBufferRenderer enqueueSampleBuffer:forDisplay];
            int64_t e = atomic_fetch_add(&s_pvEnqueued, 1) + 1;
            logPreviewStatsIfDue(e);
        }
        if (restamped) CFRelease(restamped);
        if (transformed) CFRelease(transformed);
    }
}

void blankPreviewLayersForSession(AVCaptureSession *session) {
    NSArray *layers;
    @synchronized (s_previewLayers) { layers = [[s_previewLayers allObjects] copy]; }
    for (AVCaptureVideoPreviewLayer *layer in layers) {
        if (layer.session != session) continue;
        AVSampleBufferDisplayLayer *display = objc_getAssociatedObject(layer, kGeistCamDisplayLayerKey);
        if (display) {
            // Match real-iPhone behavior: stopRunning blanks the preview within
            // a frame. Drains the renderer so the layer shows nothing on the
            // next compositor pass.
            [display.sampleBufferRenderer flushWithRemovalOfDisplayedImage:YES
                                                        completionHandler:nil];
        }
    }
}
