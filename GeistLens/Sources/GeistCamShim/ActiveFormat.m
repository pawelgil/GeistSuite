#import "ActiveFormat.h"
#import "Server.h"
#import "Source.h"
#import "Util.h"
#import <AVFoundation/AVFoundation.h>
#import <pthread.h>

typedef struct {
    BOOL set;
    int32_t width;
    int32_t height;
    uint32_t pixelFormat;
} ActiveFormatEntry;

static ActiveFormatEntry s_entries[GEISTCAM_SLOT_COUNT];
static pthread_mutex_t s_mutex = PTHREAD_MUTEX_INITIALIZER;

static BOOL slotForUID(NSString *uid, GeistCamSlot *outSlot) {
    GeistCamSource *src = findSourceByUniqueID(uid);
    if (!src) return NO;
    switch (src->kind) {
        case GeistCamSourceKind_VideoBack:  *outSlot = GEISTCAM_SLOT_BACK_CAMERA;  return YES;
        case GeistCamSourceKind_VideoFront: *outSlot = GEISTCAM_SLOT_FRONT_CAMERA; return YES;
        default: return NO;
    }
}

static void sendActiveFormat(GeistCamSlot slot, int32_t width, int32_t height, uint32_t pixfmt) {
    GeistCamActiveFormatMsg msg = {
        .slot         = (uint32_t)slot,
        .width        = (uint32_t)width,
        .height       = (uint32_t)height,
        .pixel_format = pixfmt,
    };
    serverWriteMessage(GEISTCAM_MSG_ACTIVE_FORMAT, &msg, sizeof(msg));
    char fcc[5] = { (char)(pixfmt >> 24), (char)(pixfmt >> 16),
                    (char)(pixfmt >> 8),  (char)pixfmt, 0 };
    geistcam_markerf("activeFormat: slot=%u → %dx%d %s", slot, width, height, fcc);
}

void activeFormatRecord(NSString *deviceUID, int32_t width, int32_t height, uint32_t pixfmt) {
    GeistCamSlot slot;
    if (!slotForUID(deviceUID, &slot)) return;
    pthread_mutex_lock(&s_mutex);
    ActiveFormatEntry *e = &s_entries[slot];
    BOOL changed = !e->set || e->width != width || e->height != height || e->pixelFormat != pixfmt;
    e->set         = YES;
    e->width       = width;
    e->height      = height;
    e->pixelFormat = pixfmt;
    pthread_mutex_unlock(&s_mutex);
    if (changed) sendActiveFormat(slot, width, height, pixfmt);
}

BOOL activeFormatGet(GeistCamSlot slot, int32_t *outW, int32_t *outH, uint32_t *outPF) {
    if (slot >= GEISTCAM_SLOT_COUNT) return NO;
    pthread_mutex_lock(&s_mutex);
    BOOL set = s_entries[slot].set;
    if (set) {
        if (outW)  *outW  = s_entries[slot].width;
        if (outH)  *outH  = s_entries[slot].height;
        if (outPF) *outPF = s_entries[slot].pixelFormat;
    }
    pthread_mutex_unlock(&s_mutex);
    return set;
}

void activeFormatSnapshotSession(AVCaptureSession *session) {
    if (!session) return;
    for (AVCaptureInput *input in session.inputs) {
        if (![input isKindOfClass:[AVCaptureDeviceInput class]]) continue;
        AVCaptureDevice *device = ((AVCaptureDeviceInput *)input).device;
        if (!device) continue;
        AVCaptureDeviceFormat *format = device.activeFormat;
        if (!format) continue;
        CMFormatDescriptionRef desc = format.formatDescription;
        if (!desc) continue;
        if (CMFormatDescriptionGetMediaType(desc) != kCMMediaType_Video) continue;
        CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(desc);
        OSType pixfmt = CMFormatDescriptionGetMediaSubType(desc);
        activeFormatRecord(device.uniqueID, dims.width, dims.height, pixfmt);
    }
}

void activeFormatResyncForNewFeeder(void) {
    ActiveFormatEntry snapshot[GEISTCAM_SLOT_COUNT];
    pthread_mutex_lock(&s_mutex);
    memcpy(snapshot, s_entries, sizeof(snapshot));
    pthread_mutex_unlock(&s_mutex);
    for (int i = 0; i < GEISTCAM_SLOT_COUNT; i++) {
        if (snapshot[i].set) {
            sendActiveFormat((GeistCamSlot)i, snapshot[i].width, snapshot[i].height, snapshot[i].pixelFormat);
        }
    }
}
