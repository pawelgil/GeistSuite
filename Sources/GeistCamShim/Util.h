#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

// CMCapture externs — Apple's private symbols we link against.
extern void *CMBaseObjectGetVTable(void *obj);
extern void *CMBaseObjectGetDerivedStorage(void *obj);

extern CFStringRef kFigCaptureSourceProperty_AttributesDictionary;
extern CFStringRef kFigCaptureSourceProperty_Formats;
extern CFStringRef kFigCaptureSourceAttributeKey_UniqueID;
extern CFStringRef kFigCaptureSourceAttributeKey_DeviceType;
extern CFStringRef kFigCaptureSourceAttributeKey_Position;
extern CFStringRef kFigCaptureSourceAttributeKey_LocalizedName;
extern CFStringRef kFigCaptureSourceAttributeKey_SourceType;
extern CFStringRef kFigCaptureSourceAttributeKey_MinFrameRate;
extern CFStringRef kFigCaptureSourceAttributeKey_MaxFrameRate;

extern CFArrayRef FigCaptureSourceCopySources(void);

typedef uint32_t CMBaseClassID;
typedef int32_t (*CMDerivedObjectCreateFn)(CFAllocatorRef, const void *, CMBaseClassID, void *);
typedef CMBaseClassID (*FigCaptureSourceGetClassIDFn)(void);
typedef void *(*FigSimpleMutexCreateFn)(void);

typedef int32_t OSStatusFig;

typedef enum {
    GeistCamLogError = 0,
    GeistCamLogWarn  = 1,
    GeistCamLogInfo  = 2,
    GeistCamLogDebug = 3,
} GeistCamLogLevel;

// Threshold read from $GEISTCAM_LOG_LEVEL once at first call.
// Values: error|warn|info|debug. Default: info. Calls below the threshold
// are dropped before formatting.
//
// `geistcam_marker` / `geistcam_markerf` log at Info — keeps existing call
// sites unchanged. Use `geistcam_warnf` / `geistcam_debugf` for the others.
void geistcam_marker(const char *msg);
void geistcam_markerf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void geistcam_warnf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void geistcam_debugf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

// No-op if className or selector doesn't resolve.
void swizzleMethod(NSString *className, SEL selector, IMP replacement, IMP *origOut);
