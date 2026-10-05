#import "Transform.h"
#import "ActiveFormat.h"
#import "TransformPlan.h"
#import "ImageTransform.h"
#import "RotationCoordinator.h"
#import "Server.h"
#import "Source.h"
#import "Util.h"
#import <CoreImage/CoreImage.h>
#import <stdatomic.h>

static _Atomic int64_t s_xformCalls = 0;
static _Atomic int64_t s_xformAllocs = 0;
static _Atomic int64_t s_xformOutstanding = 0;
static _Atomic int64_t s_xformFallback = 0;
static _Atomic int64_t s_xformPoolCount = 0;

@interface GeistCamSurfaceTracker : NSObject @end
@implementation GeistCamSurfaceTracker
- (void)dealloc { atomic_fetch_sub(&s_xformOutstanding, 1); }
@end

static void logXformStatsIfDue(int64_t call) {
    if (call % 1000 != 0) return;
    int64_t outstanding = atomic_load(&s_xformOutstanding);
    int64_t pools = atomic_load(&s_xformPoolCount);
    int64_t allocs = atomic_load(&s_xformAllocs);
    int64_t fallback = atomic_load(&s_xformFallback);
    BOOL alarming = (outstanding > 100) || (pools > 20);
    if (alarming) {
        geistcam_warnf("xform surfaces ALARM: outstanding=%lld pools=%lld lifetime=%lld fallback=%lld",
                       outstanding, pools, allocs, fallback);
    } else {
        geistcam_markerf("xform surfaces: outstanding=%lld pools=%lld lifetime=%lld fallback=%lld",
                         outstanding, pools, allocs, fallback);
    }
}

static BOOL transformIsIdentity(TransformParams p) {
    return !p.mirrored && p.zoomFactor <= 1.0001;
}

TransformParams transformParamsForConnection(AVCaptureConnection *conn, GeistCamTransformDelivery delivery) {
    TransformParams p = (TransformParams){ .delivery = delivery, .rotationDegrees = 0, .mirrored = NO,
        .zoomFactor = 1.0, .targetWidth = 0, .targetHeight = 0 };
    p.rotationDegrees = delivery == GeistCamTransformDeliveryDataOutput
        ? conn.videoRotationAngle : geistcam_currentCaptureRotationDegrees();
    if (conn) {
        AVCaptureDevice *device = firstDeviceInPorts(conn.inputPorts);
        if (device) {
            if ([device respondsToSelector:@selector(videoZoomFactor)]) {
                CGFloat z = device.videoZoomFactor;
                if (z >= 1.0) p.zoomFactor = z;
            }
            GeistCamSource *src = findSourceByUniqueID(device.uniqueID);
            if (src) {
                GeistCamSlot slot = (GeistCamSlot)src->kind;
                int32_t afW = 0, afH = 0;
                if (activeFormatGet(slot, &afW, &afH, NULL)) {
                    p.targetWidth = afW;
                    p.targetHeight = afH;
                }
                p.mirrored = geistcam_shouldMirror(serverGetSlotFeatures(slot),
                                                    conn.videoMirrored);
            }
        }
    }
    return p;
}

static CIContext *sharedCIContext(void) {
    static CIContext *ctx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ctx = [CIContext contextWithOptions:nil]; });
    return ctx;
}

// Pool per (w, h, format) — avoids per-frame allocation cost.
static CVPixelBufferPoolRef poolForDims(size_t w, size_t h, OSType fmt) {
    static NSMutableDictionary<NSString *, id> *pools;
    static dispatch_queue_t poolQueue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pools = [NSMutableDictionary dictionary];
        poolQueue = dispatch_queue_create("geistcam.pixelBufferPools", DISPATCH_QUEUE_SERIAL);
    });
    NSString *key = [NSString stringWithFormat:@"%zu_%zu_%u", w, h, (unsigned)fmt];
    __block CVPixelBufferPoolRef pool = NULL;
    dispatch_sync(poolQueue, ^{
        id existing = pools[key];
        if (existing) { pool = (__bridge CVPixelBufferPoolRef)existing; return; }
        NSDictionary *bufAttrs = @{
            (id)kCVPixelBufferWidthKey:           @(w),
            (id)kCVPixelBufferHeightKey:          @(h),
            (id)kCVPixelBufferPixelFormatTypeKey: @(fmt),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferMetalCompatibilityKey:  @YES,
        };
        CVPixelBufferPoolRef p = NULL;
        CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)bufAttrs, &p);
        if (p) {
            pools[key] = (__bridge_transfer id)p;
            pool = (__bridge CVPixelBufferPoolRef)pools[key];
            atomic_fetch_add(&s_xformPoolCount, 1);
        }
    });
    return pool;
}

CMSampleBufferRef applyTransformToSampleBuffer(CMSampleBufferRef sb, TransformParams params) {
    int64_t call = atomic_fetch_add(&s_xformCalls, 1) + 1;
    logXformStatsIfDue(call);

    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) return NULL;

    size_t inW = CVPixelBufferGetWidth(pb);
    size_t inH = CVPixelBufferGetHeight(pb);
    OSType inFmt = CVPixelBufferGetPixelFormatType(pb);

    GeistCamTransformPlan plan = params.delivery == GeistCamTransformDeliveryDataOutput
        ? geistcam_computePortraitDataOutputPlan(
            (int)inW, (int)inH, params.targetWidth, params.targetHeight, (int)params.rotationDegrees)
        : geistcam_computeTransformPlan(
        (int)inW, (int)inH,
        params.targetWidth, params.targetHeight,
        (int)params.rotationDegrees);
    if (transformIsIdentity(params) && plan.isIdentity) return NULL;

    CIImage *img = geistcam_imageByApplyingTransformPlan(
        [CIImage imageWithCVPixelBuffer:pb], plan, params.mirrored, params.zoomFactor);

    size_t outW = (size_t)plan.outputW;
    size_t outH = (size_t)plan.outputH;

    CVPixelBufferRef outPB = NULL;
    CVPixelBufferPoolRef pool = poolForDims(outW, outH, inFmt);
    if (pool) {
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outPB);
    }
    if (!outPB) {
        NSDictionary *attrs = @{
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        };
        CVReturn cr = CVPixelBufferCreate(kCFAllocatorDefault, outW, outH, inFmt,
                                          (__bridge CFDictionaryRef)attrs, &outPB);
        if (cr != kCVReturnSuccess || !outPB) return NULL;
        atomic_fetch_add(&s_xformFallback, 1);
    }

    [sharedCIContext() render:img toCVPixelBuffer:outPB];

    CMVideoFormatDescriptionRef fd = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, outPB, &fd);

    CMSampleTimingInfo timing = {0};
    CMSampleBufferGetSampleTimingInfo(sb, 0, &timing);

    CMSampleBufferRef out = NULL;
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, outPB, true, NULL, NULL,
                                       fd, &timing, &out);
    if (fd) CFRelease(fd);
    CFRelease(outPB);
    if (out) {
        atomic_fetch_add(&s_xformAllocs, 1);
        atomic_fetch_add(&s_xformOutstanding, 1);
        GeistCamSurfaceTracker *tracker = [GeistCamSurfaceTracker new];
        CMSetAttachment(out, CFSTR("GeistCamTracker"),
                        (__bridge CFTypeRef)tracker, kCMAttachmentMode_ShouldNotPropagate);
    }
    return out;
}
