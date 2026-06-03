#import "Metadata.h"
#import "OutputBinding.h"
#import "Server.h"
#import "Session.h"
#import "Source.h"
#import "Util.h"
#import "Wire.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <pthread.h>

static const void *kMetaDelegateKey = &kMetaDelegateKey;
static const void *kMetaQueueKey    = &kMetaQueueKey;
static const void *kMetaTypesKey    = &kMetaTypesKey;

// Both setters intentionally skip msgSendSuper to the original IMP — Apple's
// implementations route into Fig's metadata machinery, which we bypass; calls
// to the underlying Fig session crash since we never let Fig set up.
static void swiz_setMetadataObjectsDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    objc_setAssociatedObject(self, kMetaDelegateKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kMetaQueueKey, queue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    metadataInvalidateDemand();
}

static void swiz_setMetadataObjectTypes(id self, SEL _cmd, NSArray *types) {
    objc_setAssociatedObject(self, kMetaTypesKey, types, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    metadataInvalidateDemand();
}

typedef struct {
    BOOL wantsQR;
    BOOL wantsFace;
} SlotDemand;

static SlotDemand s_demand[GEISTCAM_SLOT_COUNT];
static pthread_mutex_t s_demandMutex = PTHREAD_MUTEX_INITIALIZER;

static SlotDemand computeDemandForSlot(GeistCamSlot slot) {
    SlotDemand d = {0};
    OutputBinding bindings[GEISTCAM_MAX_OUTPUTS];
    int n = snapshotOutputBindings(bindings);
    Class metaCls = NSClassFromString(@"AVCaptureMetadataOutput");
    for (int i = 0; i < n; i++) {
        GeistCamSource *src = bindings[i].source;
        if (!src || (GeistCamSlot)src->kind != slot) continue;
        if (!isSessionRunning(bindings[i].session)) continue;
        id output = bindings[i].output;
        if (!output || ![output isKindOfClass:metaCls]) continue;
        id delegate = objc_getAssociatedObject(output, kMetaDelegateKey);
        if (!delegate) continue;
        NSArray *types = objc_getAssociatedObject(output, kMetaTypesKey);
        for (AVMetadataObjectType t in types) {
            if ([t isEqualToString:AVMetadataObjectTypeQRCode]) d.wantsQR = YES;
            else if ([t isEqualToString:AVMetadataObjectTypeFace]) d.wantsFace = YES;
        }
    }
    return d;
}

static NSArray *s_cachedResults[GEISTCAM_SLOT_COUNT];
static pthread_mutex_t s_resultsMutex = PTHREAD_MUTEX_INITIALIZER;

static void clearCachedResults(GeistCamSlot slot) {
    pthread_mutex_lock(&s_resultsMutex);
    s_cachedResults[slot] = nil;
    pthread_mutex_unlock(&s_resultsMutex);
}

static void publishDemand(GeistCamSlot slot, SlotDemand demand) {
    GeistCamDemandUpdateMsg msg = { (uint32_t)slot,
                                  demand.wantsQR ? 1u : 0u,
                                  demand.wantsFace ? 1u : 0u };
    serverWriteMessage(GEISTCAM_MSG_DEMAND_UPDATE, &msg, sizeof(msg));
}

void metadataInvalidateDemand(void) {
    for (uint32_t s = 0; s < GEISTCAM_SLOT_COUNT; s++) {
        SlotDemand fresh = computeDemandForSlot((GeistCamSlot)s);
        pthread_mutex_lock(&s_demandMutex);
        BOOL changed = (s_demand[s].wantsQR != fresh.wantsQR) ||
                       (s_demand[s].wantsFace != fresh.wantsFace);
        s_demand[s] = fresh;
        pthread_mutex_unlock(&s_demandMutex);
        if (!changed) continue;
        // Demand changed → drop cached so a stopped app doesn't keep getting
        // redelivery of the last QR/face it was subscribed to.
        clearCachedResults((GeistCamSlot)s);
        publishDemand((GeistCamSlot)s, fresh);
    }
}

void metadataResyncForNewFeeder(void) {
    for (uint32_t s = 0; s < GEISTCAM_SLOT_COUNT; s++) {
        clearCachedResults((GeistCamSlot)s);
        pthread_mutex_lock(&s_demandMutex);
        SlotDemand current = s_demand[s];
        pthread_mutex_unlock(&s_demandMutex);
        publishDemand((GeistCamSlot)s, current);
    }
}

// AVMetadataObject would normally be constructed by Fig. We bypass Fig, so
// class_createInstance + getter swizzles below let us fake them.
static const void *kMOTypeKey        = &kMOTypeKey;
static const void *kMOBoundsKey      = &kMOBoundsKey;
static const void *kMOStringValueKey = &kMOStringValueKey;
static const void *kMOFaceIDKey      = &kMOFaceIDKey;

static id makeQRObject(CGRect bounds, NSString *stringValue) {
    Class cls = NSClassFromString(@"AVMetadataMachineReadableCodeObject");
    if (!cls) return nil;
    id obj = class_createInstance(cls, 0);
    if (!obj) return nil;
    objc_setAssociatedObject(obj, kMOTypeKey, AVMetadataObjectTypeQRCode,
                              OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(obj, kMOBoundsKey, [NSValue valueWithCGRect:bounds],
                              OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (stringValue) {
        objc_setAssociatedObject(obj, kMOStringValueKey, stringValue,
                                  OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return obj;
}

static id makeFaceObject(CGRect bounds, NSInteger faceID) {
    Class cls = NSClassFromString(@"AVMetadataFaceObject");
    if (!cls) return nil;
    id obj = class_createInstance(cls, 0);
    if (!obj) return nil;
    objc_setAssociatedObject(obj, kMOTypeKey, AVMetadataObjectTypeFace,
                              OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(obj, kMOBoundsKey, [NSValue valueWithCGRect:bounds],
                              OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(obj, kMOFaceIDKey, @(faceID),
                              OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return obj;
}

static AVMetadataObjectType swiz_meta_type(id self, SEL _cmd) {
    return objc_getAssociatedObject(self, kMOTypeKey);
}

static CGRect swiz_meta_bounds(id self, SEL _cmd) {
    NSValue *v = objc_getAssociatedObject(self, kMOBoundsKey);
    return v ? [v CGRectValue] : CGRectZero;
}

static CMTime swiz_meta_invalidTime(id self, SEL _cmd) {
    return kCMTimeInvalid;
}

static NSString *swiz_meta_stringValue(id self, SEL _cmd) {
    return objc_getAssociatedObject(self, kMOStringValueKey);
}

static NSArray *swiz_meta_emptyArray(id self, SEL _cmd) {
    return @[];
}

static id swiz_meta_returnNil(id self, SEL _cmd) {
    return nil;
}

static NSInteger swiz_meta_faceID(id self, SEL _cmd) {
    NSNumber *n = objc_getAssociatedObject(self, kMOFaceIDKey);
    return n.integerValue;
}

static BOOL swiz_meta_returnNO(id self, SEL _cmd) {
    return NO;
}

static CGFloat swiz_meta_returnZero(id self, SEL _cmd) {
    return 0.0;
}

void metadataHandleResultsMessage(const uint8_t *payload, size_t payloadLen) {
    if (payloadLen < sizeof(GeistCamMetadataResultsMsg)) return;
    GeistCamMetadataResultsMsg hdr;
    memcpy(&hdr, payload, sizeof(hdr));
    if (hdr.slot >= GEISTCAM_SLOT_COUNT) return;

    NSMutableArray *objects = [NSMutableArray arrayWithCapacity:hdr.object_count];
    const uint8_t *p = payload + sizeof(hdr);
    const uint8_t *end = payload + payloadLen;
    for (uint32_t i = 0; i < hdr.object_count; i++) {
        if (p + sizeof(GeistCamMetadataObjectHeader) > end) {
            geistcam_warnf("metadata: results truncated mid-object (slot=%u i=%u)",
                              hdr.slot, i);
            return;
        }
        GeistCamMetadataObjectHeader oh;
        memcpy(&oh, p, sizeof(oh));
        p += sizeof(oh);
        if (p + oh.string_len > end) {
            geistcam_warnf("metadata: results string overflow (slot=%u)", hdr.slot);
            return;
        }
        NSString *str = nil;
        if (oh.string_len > 0) {
            str = [[NSString alloc] initWithBytes:p length:oh.string_len
                                          encoding:NSUTF8StringEncoding];
        }
        p += oh.string_len;
        CGRect bounds = CGRectMake(oh.bounds_x, oh.bounds_y, oh.bounds_w, oh.bounds_h);
        id mo = nil;
        switch (oh.kind) {
            case GEISTCAM_META_KIND_QR:   mo = makeQRObject(bounds, str); break;
            case GEISTCAM_META_KIND_FACE: mo = makeFaceObject(bounds, oh.face_id); break;
            default:
                geistcam_warnf("metadata: unknown result kind=%u", oh.kind);
                break;
        }
        if (mo) [objects addObject:mo];
    }

    pthread_mutex_lock(&s_resultsMutex);
    s_cachedResults[hdr.slot] = [objects copy];
    pthread_mutex_unlock(&s_resultsMutex);
}

static void deliverMetadataObjects(NSArray *avObjects, GeistCamSource *src);

void metadataDispatchVideoFrame(CMSampleBufferRef sb, GeistCamSource *src) {
    if (!sb || !src || src->kind == GeistCamSourceKind_Audio) return;
    GeistCamSlot slot = (GeistCamSlot)src->kind;
    if ((unsigned)slot >= GEISTCAM_SLOT_COUNT) return;

    pthread_mutex_lock(&s_resultsMutex);
    NSArray *cached = s_cachedResults[slot];
    pthread_mutex_unlock(&s_resultsMutex);
    // nil = host hasn't sent results yet. Empty array IS a result — real iOS
    // fires didOutputMetadataObjects with [] so apps can clear UI.
    if (cached == nil) return;

    deliverMetadataObjects(cached, src);
}

static void deliverMetadataObjects(NSArray *avObjects, GeistCamSource *src) {
    OutputBinding bindings[GEISTCAM_MAX_OUTPUTS];
    int n = snapshotOutputBindings(bindings);
    Class metaCls = NSClassFromString(@"AVCaptureMetadataOutput");
    for (int i = 0; i < n; i++) {
        if (bindings[i].source != src) continue;
        if (!isSessionRunning(bindings[i].session)) continue;
        id output = bindings[i].output;
        if (!output || ![output isKindOfClass:metaCls]) continue;
        id delegate = objc_getAssociatedObject(output, kMetaDelegateKey);
        dispatch_queue_t queue = objc_getAssociatedObject(output, kMetaQueueKey);
        NSArray<AVMetadataObjectType> *types = objc_getAssociatedObject(output, kMetaTypesKey);
        if (!delegate || !queue || !types) continue;

        NSSet *typeSet = [NSSet setWithArray:types];
        NSMutableArray *filtered = [NSMutableArray array];
        for (id obj in avObjects) {
            AVMetadataObjectType t = ((AVMetadataObjectType (*)(id, SEL))objc_msgSend)(obj, @selector(type));
            if ([typeSet containsObject:t]) [filtered addObject:obj];
        }

        AVCaptureConnection *conn = [[output performSelector:@selector(connections)] firstObject];
        id outputRetained = output;
        id delegateRetained = delegate;
        AVCaptureConnection *connRetained = conn;
        NSArray *toShip = [filtered copy];
        dispatch_async(queue, ^{
            SEL sel = @selector(captureOutput:didOutputMetadataObjects:fromConnection:);
            if ([delegateRetained respondsToSelector:sel]) {
                void (*fn)(id, SEL, id, NSArray *, AVCaptureConnection *) = (void *)objc_msgSend;
                fn(delegateRetained, sel, outputRetained, toShip, connRetained);
            }
        });
    }
}

void installMetadataSwizzles(void) {
    swizzleMethod(@"AVCaptureMetadataOutput", @selector(setMetadataObjectsDelegate:queue:),
                  (IMP)swiz_setMetadataObjectsDelegate, NULL);
    swizzleMethod(@"AVCaptureMetadataOutput", @selector(setMetadataObjectTypes:),
                  (IMP)swiz_setMetadataObjectTypes, NULL);

    // The AVMetadataObject getter swizzles below globally hijack those methods,
    // but since we own the metadata-output delegate path end-to-end the only
    // instances apps ever receive are the ones we mint above.
    swizzleMethod(@"AVMetadataObject", @selector(type),     (IMP)swiz_meta_type,        NULL);
    swizzleMethod(@"AVMetadataObject", @selector(bounds),   (IMP)swiz_meta_bounds,      NULL);
    swizzleMethod(@"AVMetadataObject", @selector(time),     (IMP)swiz_meta_invalidTime, NULL);
    swizzleMethod(@"AVMetadataObject", @selector(duration), (IMP)swiz_meta_invalidTime, NULL);

    swizzleMethod(@"AVMetadataMachineReadableCodeObject", @selector(stringValue), (IMP)swiz_meta_stringValue, NULL);
    swizzleMethod(@"AVMetadataMachineReadableCodeObject", @selector(corners),     (IMP)swiz_meta_emptyArray,  NULL);
    swizzleMethod(@"AVMetadataMachineReadableCodeObject", @selector(descriptor),  (IMP)swiz_meta_returnNil,   NULL);

    swizzleMethod(@"AVMetadataFaceObject", @selector(faceID),       (IMP)swiz_meta_faceID,     NULL);
    swizzleMethod(@"AVMetadataFaceObject", @selector(hasYawAngle),  (IMP)swiz_meta_returnNO,   NULL);
    swizzleMethod(@"AVMetadataFaceObject", @selector(hasRollAngle), (IMP)swiz_meta_returnNO,   NULL);
    swizzleMethod(@"AVMetadataFaceObject", @selector(yawAngle),     (IMP)swiz_meta_returnZero, NULL);
    swizzleMethod(@"AVMetadataFaceObject", @selector(rollAngle),    (IMP)swiz_meta_returnZero, NULL);
}
