// Mints synthetic FigCaptureSource instances with our CopyProperty/SetProperty
// patched into the vtable, then interposes FigCaptureSourceCopySources so AVF
// discovers them. Per-frame dim mismatches are honored downstream, but the
// device's advertised format stays constant so apps that cache it stay sane.

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

typedef enum {
    GeistCamSourceKind_VideoBack  = 0,
    GeistCamSourceKind_VideoFront = 1,
    GeistCamSourceKind_Audio      = 2,
} GeistCamSourceKind;

typedef struct GeistCamSource {
    GeistCamSourceKind kind;
    void *baseObj;
    NSString *uniqueID;
    NSString *localizedName;
    int32_t devicePosition;
    int32_t deviceType;
    NSString *mediaType;

    int32_t width;
    int32_t height;
    float   frameRate;

    // Most recent video frame, kept so photo capture can snapshot synchronously.
    // CFType refs — manual CFRetain/CFRelease.
    CVPixelBufferRef latestPixelBuffer;
    CMFormatDescriptionRef latestFormatDescription;
} GeistCamSource;

#define GEISTCAM_MAX_SOURCES 3

int simSourceCount(void);
GeistCamSource *simSourceAtIndex(int i);
GeistCamSource *findSourceByObj(void *obj);
GeistCamSource *findSourceByUniqueID(NSString *uid);
GeistCamSource *findSourceByKind(GeistCamSourceKind kind);

NSString *firstDeviceUniqueIDInPorts(NSArray<AVCaptureInputPort *> *ports);
AVCaptureDevice *firstDeviceInPorts(NSArray<AVCaptureInputPort *> *ports);
