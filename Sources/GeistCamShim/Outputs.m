#import "Outputs.h"
#import "ActiveFormat.h"
#import "OutputBinding.h"
#import "Recording.h"
#import "RecordingState.h"
#import "Source.h"
#import "Util.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <objc/message.h>
#import <objc/runtime.h>

static IMP s_origMovieStartRecording;
static IMP s_origMovieStopRecording;
static IMP s_origMovieIsRecording;

static BOOL swiz_movieFile_isRecording(id self, SEL _cmd) {
    GeistCamMovieRecording *rec = objc_getAssociatedObject(self, kGeistCamRecordingKey);
    return rec != nil && rec.active;
}

static void swiz_movieFile_startRecording(id self, SEL _cmd, NSURL *url, id delegate) {
    geistcam_markerf("MovieFile startRecording: out=%p url=%s delegate=%p",
                      self, url.path.UTF8String, delegate);
    [[NSFileManager defaultManager] removeItemAtURL:url error:NULL];

    GeistCamMovieRecording *rec = [GeistCamMovieRecording new];
    rec.delegate = delegate;
    rec.outputURL = url;
    rec.active = YES;
    rec.startPTS = kCMTimeInvalid;
    objc_setAssociatedObject(self, kGeistCamRecordingKey, rec, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    recordingMovieOutputStarted(rec);

    NSArray *connections = [self performSelector:@selector(connections)];
    SEL didStartSel = @selector(captureOutput:didStartRecordingToOutputFileAtURL:fromConnections:);
    if ([delegate respondsToSelector:didStartSel]) {
        void (*fn)(id, SEL, id, NSURL *, NSArray *) = (void *)objc_msgSend;
        fn(delegate, didStartSel, self, url, connections);
    }
}

static void swiz_movieFile_stopRecording(id self, SEL _cmd) {
    GeistCamMovieRecording *rec = objc_getAssociatedObject(self, kGeistCamRecordingKey);
    if (!rec) {
        geistcam_warnf("MovieFile stopRecording: no active recording for out=%p", self);
        return;
    }
    @synchronized (rec) {
        if (!rec.active) return;
        rec.active = NO;
    }
    recordingMovieOutputStopped(rec);
    geistcam_markerf("MovieFile stopRecording: out=%p", self);
    NSArray *connections = [self performSelector:@selector(connections)];
    NSURL *url = rec.outputURL;
    id delegate = rec.delegate;
    id outputCapture = self;

    void (^postFinish)(NSError *) = ^(NSError *e) {
        SEL didFinishSel = @selector(captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:);
        if ([delegate respondsToSelector:didFinishSel]) {
            void (*fn)(id, SEL, id, NSURL *, NSArray *, NSError *) = (void *)objc_msgSend;
            fn(delegate, didFinishSel, outputCapture, url, connections, e);
        }
        objc_setAssociatedObject(outputCapture, kGeistCamRecordingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    };

    if (!rec.writer) {
        geistcam_warnf("MovieFile stopRecording: no writer (no video frames received)");
        NSError *e = [NSError errorWithDomain:AVFoundationErrorDomain code:AVErrorSessionWasInterrupted userInfo:nil];
        postFinish(e);
        return;
    }
    [rec.videoInput markAsFinished];
    [rec.audioInput markAsFinished];
    [rec.writer finishWritingWithCompletionHandler:^{
        AVAssetWriterStatus status = rec.writer.status;
        NSError *werr = rec.writer.error;
        geistcam_markerf("MovieFile finishWriting: status=%d err=%s",
                          (int)status, werr.localizedDescription.UTF8String ?: "(none)");
        NSError *cb = (status == AVAssetWriterStatusCompleted) ? nil : werr;
        postFinish(cb);
    }];
}

void installMovieFileSwizzles(void) {
    swizzleMethod(@"AVCaptureMovieFileOutput",
                  @selector(startRecordingToOutputFileURL:recordingDelegate:),
                  (IMP)swiz_movieFile_startRecording, &s_origMovieStartRecording);
    swizzleMethod(@"AVCaptureMovieFileOutput", @selector(stopRecording),
                  (IMP)swiz_movieFile_stopRecording, &s_origMovieStopRecording);
    swizzleMethod(@"AVCaptureMovieFileOutput", @selector(isRecording),
                  (IMP)swiz_movieFile_isRecording, &s_origMovieIsRecording);
}

static IMP s_origVideoDataSetDelegate;
static IMP s_origAudioDataSetDelegate;

static void recordSampleDelegate(id output, id delegate, dispatch_queue_t queue) {
    geistcam_debugf("DataOutput setSampleBufferDelegate: out=%s delegate=%p queue=%p",
                      [NSStringFromClass([output class]) UTF8String], delegate, queue);
    objc_setAssociatedObject(output, kGeistCamSampleDelegateKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(output, kGeistCamSampleQueueKey, queue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void swiz_videoData_setSampleBufferDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    recordSampleDelegate(self, delegate, queue);
    if (s_origVideoDataSetDelegate) ((void(*)(id, SEL, id, dispatch_queue_t))s_origVideoDataSetDelegate)(self, _cmd, delegate, queue);
}

static void swiz_audioData_setSampleBufferDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    recordSampleDelegate(self, delegate, queue);
    if (s_origAudioDataSetDelegate) ((void(*)(id, SEL, id, dispatch_queue_t))s_origAudioDataSetDelegate)(self, _cmd, delegate, queue);
}

// The iOS Simulator exposes no real audio input device, so AVF's recommended
// asset-writer settings come back with sampleRate 0, which AVAssetWriter
// canApply: rejects. We stream mic audio over the socket at a known rate;
// patch it in (preserving Apple's other keys) so the app's audio input builds.
static IMP s_origRecommendedAudioSettings;
static NSDictionary *swiz_audioData_recommendedSettings(id self, SEL _cmd, NSString *fileType) {
    NSDictionary *orig = s_origRecommendedAudioSettings
        ? ((NSDictionary *(*)(id, SEL, NSString *))s_origRecommendedAudioSettings)(self, _cmd, fileType)
        : nil;
    NSNumber *rate = orig[AVSampleRateKey];
    if (rate != nil && rate.doubleValue > 0) return orig;

    GeistCamSource *mic = findSourceByKind(GeistCamSourceKind_Audio);
    double micRate = (mic && mic->frameRate > 0) ? (double)mic->frameRate : 48000.0;
    NSMutableDictionary *patched = orig ? [orig mutableCopy] : [NSMutableDictionary dictionary];
    patched[AVSampleRateKey] = @(micRate);
    if (!patched[AVFormatIDKey]) patched[AVFormatIDKey] = @(kAudioFormatMPEG4AAC);
    if (!patched[AVNumberOfChannelsKey]) patched[AVNumberOfChannelsKey] = @(1);

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        geistcam_markerf("recommendedAudioSettings: sim has no audio device; patched sampleRate -> %.0f", micRate);
    });
    return patched;
}

// The shim delivers 4:2:0 YUV to data-output delegates and does not transcode to
// an app-requested output format. Surface the cases we don't honor (e.g. BGRA) so
// they show up in shim.log / Report Issue bundles instead of as silent wrong colors.
static IMP s_origSetVideoSettings;
static void swiz_videoData_setVideoSettings(id self, SEL _cmd, NSDictionary *settings) {
    if (s_origSetVideoSettings) ((void(*)(id, SEL, NSDictionary *))s_origSetVideoSettings)(self, _cmd, settings);
    NSNumber *pf = settings[(id)kCVPixelBufferPixelFormatTypeKey];
    if (!pf) return;
    OSType fmt = (OSType)pf.unsignedIntValue;
    if (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
        fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) return;
    char fcc[5] = { (char)(fmt >> 24), (char)(fmt >> 16), (char)(fmt >> 8), (char)fmt, 0 };
    geistcam_warnf("AVCaptureVideoDataOutput requested pixel format '%s' (0x%08x) — shim delivers "
                   "4:2:0 YUV and does not transcode; this output's delegate buffers will be YUV, "
                   "not the requested format", fcc, fmt);
}

void installDataOutputSwizzles(void) {
    swizzleMethod(@"AVCaptureVideoDataOutput",
                  @selector(setSampleBufferDelegate:queue:),
                  (IMP)swiz_videoData_setSampleBufferDelegate, &s_origVideoDataSetDelegate);
    swizzleMethod(@"AVCaptureVideoDataOutput",
                  @selector(setVideoSettings:),
                  (IMP)swiz_videoData_setVideoSettings, &s_origSetVideoSettings);
    swizzleMethod(@"AVCaptureAudioDataOutput",
                  @selector(setSampleBufferDelegate:queue:),
                  (IMP)swiz_audioData_setSampleBufferDelegate, &s_origAudioDataSetDelegate);
    swizzleMethod(@"AVCaptureAudioDataOutput",
                  @selector(recommendedAudioSettingsForAssetWriterWithOutputFileType:),
                  (IMP)swiz_audioData_recommendedSettings, &s_origRecommendedAudioSettings);
}

// Photo capture path: snapshot the bound source's latestPixelBuffer, JPEG-encode
// via CIContext, mint a bare AVCapturePhoto via class_createInstance (no public
// init; private one runs Fig setup we bypass), then drive the delegate lifecycle
// ourselves. JPEG comes back through swizzled fileDataRepresentation.
static IMP s_origPhotoCapturePhoto;
static IMP s_origPhotoAvailableCodecTypes;
static IMP s_origAVCapturePhotoFileDataRep;
static const void *kGeistCamPhotoJPEGKey = &kGeistCamPhotoJPEGKey;
static const void *kGeistCamPhotoSettingsKey = &kGeistCamPhotoSettingsKey;

static NSData *encodePixelBufferToJPEG(CVPixelBufferRef pb) {
    if (!pb) return nil;
    static CIContext *ctx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ctx = [CIContext contextWithOptions:nil]; });
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pb];
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    NSData *data = [ctx JPEGRepresentationOfImage:ciImage colorSpace:cs options:@{}];
    CGColorSpaceRelease(cs);
    return data;
}

static NSData *swiz_avcapturephoto_fileDataRepresentation(id self, SEL _cmd) {
    NSData *associated = objc_getAssociatedObject(self, kGeistCamPhotoJPEGKey);
    if (associated) return associated;
    if (s_origAVCapturePhotoFileDataRep) {
        return ((NSData *(*)(id, SEL))s_origAVCapturePhotoFileDataRep)(self, _cmd);
    }
    return nil;
}

// AVCam picks HEVC when availablePhotoCodecTypes contains it, and AVF's
// HEVC photo code path doesn't reach our shim. Restrict to JPEG.
static NSArray *swiz_photo_availableCodecTypes(id self, SEL _cmd) {
    return @[ AVVideoCodecTypeJPEG ];
}

// Falls back to the first back-camera GeistCamSource because photo outputs in our
// setup sometimes lack resolvable connections.
static GeistCamSource *findVideoSourceForPhotoOutput(id photoOutput) {
    for (AVCaptureConnection *conn in [photoOutput connections]) {
        GeistCamSource *src = findSourceByUniqueID(firstDeviceUniqueIDInPorts(conn.inputPorts));
        if (src && src->kind != GeistCamSourceKind_Audio) return src;
    }
    for (int i = 0; i < simSourceCount(); i++) {
        GeistCamSource *s = simSourceAtIndex(i);
        if (s->kind == GeistCamSourceKind_VideoBack) return s;
    }
    return NULL;
}

// Bare AVCapturePhoto via class_createInstance — getter swizzles below
// surface JPEG/resolvedSettings; everything else returns nil/empty (matches
// real iPhone behavior for disabled features).
static id constructGeistCamAVCapturePhoto(id resolvedSettings, NSData *jpeg) {
    Class photoCls = NSClassFromString(@"AVCapturePhoto");
    if (!photoCls) return nil;
    id photo = class_createInstance(photoCls, 0);
    if (!photo) return nil;
    if (jpeg) objc_setAssociatedObject(photo, kGeistCamPhotoJPEGKey, jpeg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (resolvedSettings) objc_setAssociatedObject(photo, kGeistCamPhotoSettingsKey, resolvedSettings, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return photo;
}

static IMP s_origPhotoResolvedSettingsGetter;
static id swiz_photo_resolvedSettings(id self, SEL _cmd) {
    id assoc = objc_getAssociatedObject(self, kGeistCamPhotoSettingsKey);
    if (assoc) return assoc;
    if (s_origPhotoResolvedSettingsGetter) {
        return ((id(*)(id, SEL))s_origPhotoResolvedSettingsGetter)(self, _cmd);
    }
    return nil;
}

// Real AVCapturePhoto getters dereference ivars our class_createInstance'd
// instance left zero-init — explicit nil/empty avoids the segfault.
static id swiz_photo_returnEmptyDict(id self, SEL _cmd) { return @{}; }
static id swiz_photo_returnNil(id self, SEL _cmd) { return nil; }
static id swiz_photo_semanticMatteForType(id self, SEL _cmd, id type) { return nil; }
static CGImageRef swiz_photo_returnNullImage(id self, SEL _cmd) { return NULL; }
static CVPixelBufferRef swiz_photo_returnNullPB(id self, SEL _cmd) { return NULL; }

static void swiz_photo_capturePhoto(id self, SEL _cmd, id settings, id delegate) {
    long long settingsID = [[settings valueForKey:@"uniqueID"] longLongValue];
    geistcam_debugf("PhotoOutput capturePhoto: out=%p settingsID=%lld delegate=%p", self, settingsID, delegate);

    GeistCamSource *src = findVideoSourceForPhotoOutput(self);
    CVPixelBufferRef pb = src ? src->latestPixelBuffer : NULL;
    if (pb) CFRetain(pb);

    NSData *jpeg = nil;
    NSError *captureError = nil;
    if (!src || !pb) {
        captureError = [NSError errorWithDomain:AVFoundationErrorDomain code:AVErrorSessionWasInterrupted userInfo:@{
            NSLocalizedDescriptionKey: @"No frame available — session not running"
        }];
        geistcam_warnf("PhotoOutput capturePhoto: no source frame available");
    } else {
        jpeg = encodePixelBufferToJPEG(pb);
        if (jpeg) {
            geistcam_debugf("PhotoOutput capturePhoto: encoded jpeg=%lu bytes", (unsigned long)jpeg.length);
        } else {
            captureError = [NSError errorWithDomain:AVFoundationErrorDomain code:-1 userInfo:@{
                NSLocalizedDescriptionKey: @"Encoding failed"
            }];
        }
        CFRelease(pb);
    }

    // Bare AVCaptureResolvedPhotoSettings — uniqueID reads off an ivar we
    // can't set without further RE; apps treat the resulting 0 as a fresh
    // capture, which is fine for the JPEG path AVCam-style apps exercise.
    Class resolvedCls = NSClassFromString(@"AVCaptureResolvedPhotoSettings");
    id resolved = nil;
    if (resolvedCls) {
        resolved = class_createInstance(resolvedCls, 0);
    }

    id photo = constructGeistCamAVCapturePhoto(resolved, jpeg);

    // We skip willBegin/willCapture/didCapture/didFinishCapture callbacks —
    // they hand over AVCaptureResolvedPhotoSettings whose uninitialized struct
    // ivars (livePhotoMovieDimensions, photoProcessingTimeRange, …) crash
    // delegates that read them. didFinishProcessingPhoto only needs the
    // AVCapturePhoto, which we control via associated objects.
    id delegateRetained = delegate;
    id outputRetained = self;
    id photoRetained = photo;
    NSError *errorRetained = captureError;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // ObjC selectors are `captureOutput:`; Swift's `photoOutput:` is
        // NS_SWIFT_NAME sugar over the same underlying selector.
        SEL didFinishPhotoSel = NSSelectorFromString(@"captureOutput:didFinishProcessingPhoto:error:");
        if ([delegateRetained respondsToSelector:didFinishPhotoSel]) {
            void (*fn)(id, SEL, id, id, id) = (void *)objc_msgSend;
            fn(delegateRetained, didFinishPhotoSel, outputRetained, photoRetained, errorRetained);
        }
        SEL didFinishCaptureSel = NSSelectorFromString(@"captureOutput:didFinishCaptureForResolvedSettings:error:");
        id resolvedFallback = objc_getAssociatedObject(photoRetained, kGeistCamPhotoSettingsKey);
        if (resolvedFallback && [delegateRetained respondsToSelector:didFinishCaptureSel]) {
            void (*fn)(id, SEL, id, id, id) = (void *)objc_msgSend;
            fn(delegateRetained, didFinishCaptureSel, outputRetained, resolvedFallback, errorRetained);
        }
    });
    // Skip original — Apple's path drives Fig's iris vtable, which errors
    // out and delivers an error to the delegate after we just delivered success.
}

void installPhotoSwizzles(void) {
    swizzleMethod(@"AVCapturePhotoOutput", @selector(capturePhotoWithSettings:delegate:),
                  (IMP)swiz_photo_capturePhoto, &s_origPhotoCapturePhoto);
    swizzleMethod(@"AVCapturePhotoOutput", @selector(availablePhotoCodecTypes),
                  (IMP)swiz_photo_availableCodecTypes, &s_origPhotoAvailableCodecTypes);
    swizzleMethod(@"AVCapturePhoto", @selector(fileDataRepresentation),
                  (IMP)swiz_avcapturephoto_fileDataRepresentation, &s_origAVCapturePhotoFileDataRep);
    swizzleMethod(@"AVCapturePhoto", @selector(resolvedSettings),
                  (IMP)swiz_photo_resolvedSettings, &s_origPhotoResolvedSettingsGetter);
    swizzleMethod(@"AVCapturePhoto", @selector(metadata),
                  (IMP)swiz_photo_returnEmptyDict, NULL);
    swizzleMethod(@"AVCapturePhoto", @selector(portraitEffectsMatte),
                  (IMP)swiz_photo_returnNil, NULL);
    swizzleMethod(@"AVCapturePhoto", @selector(depthData),
                  (IMP)swiz_photo_returnNil, NULL);
    swizzleMethod(@"AVCapturePhoto", @selector(cameraCalibrationData),
                  (IMP)swiz_photo_returnNil, NULL);
    swizzleMethod(@"AVCapturePhoto", @selector(semanticSegmentationMatteForType:),
                  (IMP)swiz_photo_semanticMatteForType, NULL);
    swizzleMethod(@"AVCapturePhoto", @selector(CGImageRepresentation),
                  (IMP)swiz_photo_returnNullImage, NULL);
    swizzleMethod(@"AVCapturePhoto", @selector(previewCGImageRepresentation),
                  (IMP)swiz_photo_returnNullImage, NULL);
    swizzleMethod(@"AVCapturePhoto", @selector(pixelBuffer),
                  (IMP)swiz_photo_returnNullPB, NULL);
    swizzleMethod(@"AVCapturePhoto", @selector(previewPixelBuffer),
                  (IMP)swiz_photo_returnNullPB, NULL);
    swizzleMethod(@"AVCapturePhoto", @selector(embeddedThumbnailPhotoFormat),
                  (IMP)swiz_photo_returnNil, NULL);
}

static BOOL swiz_isLockedForConfiguration(id self, SEL _cmd) {
    return YES;
}

static BOOL swiz_conn_returnYES(id self, SEL _cmd) {
    return YES;
}

static BOOL swiz_conn_isVideoRotationAngleSupported(id self, SEL _cmd, double angle) {
    return angle == 0.0 || angle == 90.0 || angle == 180.0 || angle == 270.0;
}

static IMP s_origDeviceSetActiveFormat;
static void swiz_device_setActiveFormat(id self, SEL _cmd, id format, BOOL reset, NSString *preset) {
    if (s_origDeviceSetActiveFormat) {
        ((void(*)(id, SEL, id, BOOL, NSString *))s_origDeviceSetActiveFormat)(self, _cmd, format, reset, preset);
    }
    if (!format) return;
    if (![self isKindOfClass:[AVCaptureDevice class]]) return;
    NSString *uid = [(AVCaptureDevice *)self uniqueID];
    if (!uid) return;
    SEL fdSel = @selector(formatDescription);
    if (![format respondsToSelector:fdSel]) return;
    id descObj = ((id(*)(id, SEL))objc_msgSend)(format, fdSel);
    CMFormatDescriptionRef desc = (__bridge CMFormatDescriptionRef)descObj;
    if (!desc) return;
    if (CMFormatDescriptionGetMediaType(desc) != kCMMediaType_Video) return;
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(desc);
    OSType pixfmt = CMFormatDescriptionGetMediaSubType(desc);
    activeFormatRecord(uid, dims.width, dims.height, pixfmt);
}

static float swiz_format_maxZoomFactor(id self, SEL _cmd) {
    return 8.0f;
}

static IMP s_origDefaultDeviceWithMediaType;
static id swiz_defaultDeviceWithMediaType(Class self, SEL _cmd, NSString *mediaType) {
    if ([mediaType isEqualToString:@"soun"]) {
        SEL deviceWithUID = NSSelectorFromString(@"deviceWithUniqueID:");
        if ([self respondsToSelector:deviceWithUID]) {
            id correct = ((id(*)(Class, SEL, NSString *))objc_msgSend)(self, deviceWithUID,
                @"com.apple.avfoundation.avcapturedevice.built-in_audio:0");
            if (correct) return correct;
        }
    }
    return s_origDefaultDeviceWithMediaType ? ((id(*)(Class, SEL, NSString *))s_origDefaultDeviceWithMediaType)(self, _cmd, mediaType) : nil;
}

void installCapabilitySwizzles(void) {
    swizzleMethod(@"AVCaptureFigVideoDevice", @selector(isLockedForConfiguration),
                  (IMP)swiz_isLockedForConfiguration, NULL);
    swizzleMethod(@"AVCaptureFigAudioDevice", @selector(isLockedForConfiguration),
                  (IMP)swiz_isLockedForConfiguration, NULL);
    swizzleMethod(@"AVCaptureFigVideoDevice",
                  NSSelectorFromString(@"_setActiveFormat:resetVideoZoomFactorAndMinMaxFrameDurations:sessionPreset:"),
                  (IMP)swiz_device_setActiveFormat, &s_origDeviceSetActiveFormat);
    swizzleMethod(@"FigCaptureSourceVideoFormat", @selector(maxZoomFactor),
                  (IMP)swiz_format_maxZoomFactor, NULL);
    swizzleMethod(@"AVCaptureConnection", @selector(isVideoOrientationSupported),
                  (IMP)swiz_conn_returnYES, NULL);
    swizzleMethod(@"AVCaptureConnection", NSSelectorFromString(@"isVideoMirroringSupported"),
                  (IMP)swiz_conn_returnYES, NULL);
    swizzleMethod(@"AVCaptureConnection", @selector(isVideoRotationAngleSupported:),
                  (IMP)swiz_conn_isVideoRotationAngleSupported, NULL);
    // Class method — swizzleMethod only handles instance methods, so inline.
    Class cls = NSClassFromString(@"AVCaptureDevice");
    Method m = cls ? class_getClassMethod(cls, @selector(defaultDeviceWithMediaType:)) : NULL;
    if (m) {
        s_origDefaultDeviceWithMediaType = method_setImplementation(m, (IMP)swiz_defaultDeviceWithMediaType);
        geistcam_debugf("swizzled +[AVCaptureDevice defaultDeviceWithMediaType:]");
    }
}
