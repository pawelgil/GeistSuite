#import "Source.h"
#import "Server.h"
#import "SerializedSourceProvider.h"
#import "SourceAttributes.h"
#import "SourceEnumeration.h"
#import "Util.h"
#import "Wire.h"
#import <objc/message.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <unistd.h>

static CMDerivedObjectCreateFn      g_CMDerivedObjectCreate;
static FigCaptureSourceGetClassIDFn g_FigCaptureSourceGetClassID;
static FigSimpleMutexCreateFn       g_FigSimpleMutexCreate;
static GeistCamSourceEnumeration    g_sourceEnumeration;
static GeistCamSourceAttributes     g_sourceAttributes;
static GeistCamSerializedSourceProvider *g_sourceProvider;
static CFStringRef                  g_localizedNameKey;
static CFStringRef                  g_minFrameRateKey;
static CFStringRef                  g_maxFrameRateKey;

static CFStringRef resolveCFStringConstant(const char *symbol) {
    CFStringRef *address = (CFStringRef *)dlsym(RTLD_DEFAULT, symbol);
    return address ? *address : NULL;
}

static int resolveCMCaptureSymbols(void) {
    if (g_CMDerivedObjectCreate && g_FigCaptureSourceGetClassID && g_FigSimpleMutexCreate) return 0;
    g_CMDerivedObjectCreate      = (CMDerivedObjectCreateFn)dlsym(RTLD_DEFAULT, "CMDerivedObjectCreate");
    g_FigCaptureSourceGetClassID = (FigCaptureSourceGetClassIDFn)dlsym(RTLD_DEFAULT, "FigCaptureSourceGetClassID");
    g_FigSimpleMutexCreate       = (FigSimpleMutexCreateFn)dlsym(RTLD_DEFAULT, "FigSimpleMutexCreate");
    if (!g_CMDerivedObjectCreate || !g_FigCaptureSourceGetClassID || !g_FigSimpleMutexCreate) {
        geistcam_warnf("dlsym: failed to resolve required CMCapture symbols");
        return -1;
    }
    return 0;
}

static id makeFigCaptureSourceVideoFormat(int32_t width, int32_t height, float frameRate,
                                          OSType pixelFormat, BOOL isDefault, NSArray *presets) {
    Class cls = NSClassFromString(@"FigCaptureSourceVideoFormat");
    if (!cls) return nil;
    CMVideoFormatDescriptionRef fmtDesc = NULL;
    OSStatus s = CMVideoFormatDescriptionCreate(kCFAllocatorDefault, pixelFormat, width, height, NULL, &fmtDesc);
    if (s != 0 || !fmtDesc) {
        geistcam_warnf("CMVideoFormatDescriptionCreate failed: %d", (int)s);
        return nil;
    }
    char fcc[5] = { (char)(pixelFormat >> 24), (char)(pixelFormat >> 16),
                    (char)(pixelFormat >> 8),  (char)pixelFormat, 0 };
    NSDictionary *dict = @{
        @"Name": [NSString stringWithFormat:@"%dx%d_%s_%.0ffps", width, height, fcc, frameRate],
        @"Width": @(width),
        @"Height": @(height),
        @"VideoMinFrameRate": @(MIN(15.0f, frameRate)),
        @"VideoMaxFrameRate": @(frameRate),
        @"VideoDefaultMinFrameRate": @(MIN(15.0f, frameRate)),
        @"VideoDefaultMaxFrameRate": @(frameRate),
        @"FormatDescription": (__bridge id)fmtDesc,
        @"DefaultActiveFormat": @(isDefault),
        @"MediaType": @"vide",
        (id)kCVPixelBufferPixelFormatTypeKey: @(pixelFormat),
        @"AVCaptureSessionPresets": presets,
        @"VideoMaxZoomFactor": @(8.0),
        @"VideoZoomFactorUpscaleThreshold": @(1.0),
    };
    SEL initSel = NSSelectorFromString(@"initWithFigCaptureStreamFormatDictionary:");
    id (*initFn)(id, SEL, NSDictionary *) = (void *)objc_msgSend;
    id alloc = [cls alloc];
    id fmt = nil;
    @try {
        fmt = initFn(alloc, initSel, dict);
    } @catch (NSException *ex) {
        geistcam_warnf("FigCaptureSourceVideoFormat init threw: %s — %s",
                          ex.name.UTF8String, ex.reason.UTF8String);
        fmt = nil;
    }
    CFRelease(fmtDesc);
    return fmt;
}

// Resolution matrix advertised to AVF. Both 420f and 420v are minted at each
// dim — the session-level format picker normalizes the output's required
// pixel format to ONE of them (BGRA/420f → 420f source; nothing requested →
// 420v source), then the device picker requires an EXACT subtype match for
// built-in cameras. Independent of wire source dims; the lib reformats to
// match the chosen activeFormat (signaled via the ACTIVE_FORMAT wire msg).
static NSArray *makeFigCaptureSourceVideoFormats(float frameRate) {
    struct { int32_t w; int32_t h; NSString *dimPreset; NSString *qualityPreset; BOOL isDefault; }
    variants[] = {
        { 640,  480,  @"AVCaptureSessionPreset640x480",   @"AVCaptureSessionPresetLow",    NO  },
        { 1280, 720,  @"AVCaptureSessionPreset1280x720",  @"AVCaptureSessionPresetMedium", NO  },
        { 1920, 1080, @"AVCaptureSessionPreset1920x1080", @"AVCaptureSessionPresetHigh",   YES },
        { 3840, 2160, @"AVCaptureSessionPreset3840x2160", nil,                              NO  },
    };
    NSMutableArray *fmts = [NSMutableArray array];
    for (size_t i = 0; i < sizeof(variants) / sizeof(*variants); i++) {
        NSMutableArray *presets = [NSMutableArray array];
        [presets addObject:variants[i].dimPreset];
        if (variants[i].qualityPreset) [presets addObject:variants[i].qualityPreset];
        [presets addObject:@"AVCaptureSessionPresetInputPriority"];
        [presets addObject:@"AVCaptureSessionPresetPhoto"];

        id fmt420f = makeFigCaptureSourceVideoFormat(variants[i].w, variants[i].h, frameRate,
                                                      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                                      variants[i].isDefault, presets);
        if (fmt420f) [fmts addObject:fmt420f];

        id fmt420v = makeFigCaptureSourceVideoFormat(variants[i].w, variants[i].h, frameRate,
                                                      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                                      NO, presets);
        if (fmt420v) [fmts addObject:fmt420v];
    }
    geistcam_markerf("built %lu video format(s) @%.1ffps", (unsigned long)fmts.count, frameRate);
    return fmts;
}

static GeistCamSource s_sources[GEISTCAM_MAX_SOURCES];
static _Atomic int s_sourceCount = 0;

int simSourceCount(void) { return atomic_load_explicit(&s_sourceCount, memory_order_acquire); }
GeistCamSource *simSourceAtIndex(int i) {
    int count = atomic_load_explicit(&s_sourceCount, memory_order_acquire);
    return (i >= 0 && i < count) ? &s_sources[i] : NULL;
}

GeistCamSource *findSourceByObj(void *obj) {
    int count = atomic_load_explicit(&s_sourceCount, memory_order_acquire);
    for (int i = 0; i < count; i++) {
        if (s_sources[i].baseObj == obj) return &s_sources[i];
    }
    return NULL;
}

GeistCamSource *findSourceByUniqueID(NSString *uid) {
    if (!uid) return NULL;
    int count = atomic_load_explicit(&s_sourceCount, memory_order_acquire);
    for (int i = 0; i < count; i++) {
        if ([s_sources[i].uniqueID isEqualToString:uid]) return &s_sources[i];
    }
    return NULL;
}

GeistCamSource *findSourceByKind(GeistCamSourceKind kind) {
    int count = atomic_load_explicit(&s_sourceCount, memory_order_acquire);
    for (int i = 0; i < count; i++) {
        if (s_sources[i].kind == kind) return &s_sources[i];
    }
    return NULL;
}

NSString *firstDeviceUniqueIDInPorts(NSArray<AVCaptureInputPort *> *ports) {
    for (AVCaptureInputPort *port in ports) {
        if ([port.input isKindOfClass:[AVCaptureDeviceInput class]]) {
            return ((AVCaptureDeviceInput *)port.input).device.uniqueID;
        }
    }
    return nil;
}

AVCaptureDevice *firstDeviceInPorts(NSArray<AVCaptureInputPort *> *ports) {
    for (AVCaptureInputPort *port in ports) {
        if ([port.input isKindOfClass:[AVCaptureDeviceInput class]]) {
            return ((AVCaptureDeviceInput *)port.input).device;
        }
    }
    return nil;
}

static NSDictionary *makeAttributesDictionaryFor(GeistCamSource *src) {
    if (!src) return @{};
    NSMutableDictionary *attributes = [@{
        (__bridge id)kFigCaptureSourceAttributeKey_UniqueID:      src->uniqueID,
        (__bridge id)kFigCaptureSourceAttributeKey_DeviceType:    @(src->deviceType),
        (__bridge id)kFigCaptureSourceAttributeKey_Position:      @(src->devicePosition),
        (__bridge id)(g_localizedNameKey ?: CFSTR("LocalizedName")): src->localizedName,
        (__bridge id)kFigCaptureSourceAttributeKey_SourceType:    @(0),
    } mutableCopy];
    if (g_sourceAttributes.mode == GeistCamSourceAttributesModeLegacyDictionary) {
        if (g_minFrameRateKey) attributes[(__bridge id)g_minFrameRateKey] = @(15.0);
        if (g_maxFrameRateKey) attributes[(__bridge id)g_maxFrameRateKey] = @(30.0);
    }
    return attributes;
}

typedef OSStatusFig (*FigCopyPropertyFn)(void *, CFStringRef, CFAllocatorRef, CFTypeRef *);
typedef OSStatusFig (*FigSetPropertyFn)(void *, CFStringRef, CFTypeRef);

static FigCopyPropertyFn s_originalCopyProperty;
static FigSetPropertyFn s_originalSetProperty;

static OSStatusFig our_CopyProperty(void *obj, CFStringRef key, CFAllocatorRef allocator, CFTypeRef *outValue) {
    GeistCamSource *src = findSourceByObj(obj);
    if (!src) return s_originalCopyProperty ? s_originalCopyProperty(obj, key, allocator, outValue) : -16463;
    if (!key || !outValue) return -16463;
    *outValue = NULL;
    if (g_sourceAttributes.propertyKey && CFEqual(key, g_sourceAttributes.propertyKey)) {
        *outValue = geistcam_createSourceAttributes(
            g_sourceAttributes,
            makeAttributesDictionaryFor(src)
        );
        return *outValue ? 0 : -16463;
    }
    if (CFEqual(key, kFigCaptureSourceProperty_Formats)) {
        if (src && src->kind == GeistCamSourceKind_Audio) {
            *outValue = CFBridgingRetain(@[]);
            return 0;
        }
        NSArray *arr = src ? makeFigCaptureSourceVideoFormats(src->frameRate) : @[];
        *outValue = CFBridgingRetain(arr);
        return 0;
    }
    return -16463;
}

static OSStatusFig our_SetProperty(void *obj, CFStringRef key, CFTypeRef value) {
    if (!findSourceByObj(obj)) {
        return s_originalSetProperty ? s_originalSetProperty(obj, key, value) : -16463;
    }
    return 0;
}

static int s_vtablePatched = 0;
static const void *s_simSourceVTable;

static int patchVTableFromLiveSource(void *src) {
    if (s_vtablePatched) return 0;
    if (!src) return -1;
    if (resolveCMCaptureSymbols() != 0) return -5;
    void *vt = CMBaseObjectGetVTable(src);
    if (!vt) return -2;
    s_simSourceVTable = vt;
    void *baseClass = ((void **)vt)[1];
    if (!baseClass) return -3;
    void **slot6 = (void **)((char *)baseClass + 0x30);
    void **slot7 = (void **)((char *)baseClass + 0x38);
    FigCopyPropertyFn originalCopyProperty = (FigCopyPropertyFn)*slot6;
    FigSetPropertyFn originalSetProperty = (FigSetPropertyFn)*slot7;
    if (originalCopyProperty == our_CopyProperty || originalSetProperty == our_SetProperty) return -6;

    vm_size_t pageSize = (vm_size_t)sysconf(_SC_PAGE_SIZE);
    vm_address_t pageStart = (vm_address_t)slot6 & ~((vm_address_t)pageSize - 1);
    kern_return_t kr = vm_protect(mach_task_self(), pageStart, pageSize, FALSE,
                                   VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        kr = vm_protect(mach_task_self(), pageStart, pageSize, FALSE,
                        VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
        if (kr != KERN_SUCCESS) return -4;
    }
    s_originalCopyProperty = originalCopyProperty;
    s_originalSetProperty = originalSetProperty;
    *slot6 = (void *)&our_CopyProperty;
    *slot7 = (void *)&our_SetProperty;
    vm_protect(mach_task_self(), pageStart, pageSize, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    s_vtablePatched = 1;
    geistcam_markerf("patched FigCaptureSource BaseClass[6,7] -> our_CopyProperty/SetProperty");
    return 0;
}

static void *mintFigCaptureSource(void) {
    if (!s_simSourceVTable) return NULL;
    if (resolveCMCaptureSymbols() != 0) return NULL;
    void *out = NULL;
    int32_t status = g_CMDerivedObjectCreate(kCFAllocatorDefault,
                                              s_simSourceVTable,
                                              g_FigCaptureSourceGetClassID(),
                                              &out);
    if (status != 0 || !out) return NULL;
    void *storage = CMBaseObjectGetDerivedStorage(out);
    if (storage) {
        *(void **)((char *)storage + 0x8) = g_FigSimpleMutexCreate();
    }
    return out;
}

static void registerGeistCamSource(GeistCamSourceKind kind,
                               NSString *uniqueID,
                               NSString *localizedName,
                               int32_t position,
                               NSString *mediaType,
                               int32_t width,
                               int32_t height,
                               float frameRate) {
    int index = atomic_load_explicit(&s_sourceCount, memory_order_relaxed);
    if (index >= GEISTCAM_MAX_SOURCES) return;
    void *baseObj = mintFigCaptureSource();
    if (!baseObj) return;
    s_sources[index] = (GeistCamSource){
        .kind = kind,
        .baseObj = baseObj,
        .uniqueID = uniqueID,
        .localizedName = localizedName,
        .devicePosition = position,
        .deviceType = (kind == GeistCamSourceKind_Audio) ? 0 : 2,
        .mediaType = mediaType,
        .width = width,
        .height = height,
        .frameRate = frameRate,
    };
    geistcam_markerf("registered GeistCamSource[%d] kind=%d uid='%s' %dx%d@%.1ffps",
                      index, (int)kind, uniqueID.UTF8String, width, height, frameRate);
    atomic_store_explicit(&s_sourceCount, index + 1, memory_order_release);
}

static BOOL buildGeistCamSources(NSArray *appleSources) {
    if (atomic_load_explicit(&s_sourceCount, memory_order_acquire) > 0) return YES;

    GeistCamSlotInfo slots[GEISTCAM_SLOT_COUNT] = {0};
    BOOL configured[GEISTCAM_SLOT_COUNT] = {NO, NO, NO};
    if (!serverWaitForHello(/*timeoutSec*/ 5.0, slots, configured)) {
        geistcam_warnf("buildGeistCamSources: no HELLO from feeder within 5s — "
                         "source enumeration will fall back to Apple's default sim camera. "
                         "If you expected GeistCam to be active, ensure "
                         "GeistCamSession.start() runs before the app calls "
                         "AVCaptureDevice.devices.");
        return NO;
    }

    BOOL hasConfiguredSlot = NO;
    for (size_t i = 0; i < GEISTCAM_SLOT_COUNT; i++) {
        if (configured[i]) {
            hasConfiguredSlot = YES;
            break;
        }
    }
    if (!hasConfiguredSlot) {
        geistcam_warnf("buildGeistCamSources: HELLO arrived but no slots configured — "
                       "feeder attached no producers. Using Apple's camera sources.");
        return NO;
    }
    if (resolveCMCaptureSymbols() != 0) return NO;
    if (appleSources.count == 0 || patchVTableFromLiveSource((__bridge void *)appleSources.firstObject) != 0) {
        geistcam_warnf("buildGeistCamSources: unable to prepare FigCaptureSource creation");
        return NO;
    }

    struct { GeistCamSourceKind kind; NSString *uid; NSString *name; int32_t pos; NSString *media; }
    descriptors[] = {
        { GeistCamSourceKind_VideoBack,  @"sim-camera-back-wide-0001",  @"GeistCam (Back Wide)",  1, @"vide" },
        { GeistCamSourceKind_VideoFront, @"sim-camera-front-wide-0001", @"GeistCam (Front Wide)", 2, @"vide" },
        { GeistCamSourceKind_Audio,      @"com.apple.avfoundation.avcapturedevice.built-in_audio:0",
                                    @"GeistCam Microphone",       0, @"soun" },
    };
    for (size_t i = 0; i < sizeof(descriptors) / sizeof(*descriptors); i++) {
        if (!configured[i]) continue;
        GeistCamSlotInfo info = slots[i];
        float fps = (info.fps_den > 0) ? (float)info.fps_num / (float)info.fps_den : 0.0f;
        registerGeistCamSource(descriptors[i].kind, descriptors[i].uid, descriptors[i].name,
                          descriptors[i].pos, descriptors[i].media,
                          (int32_t)info.width, (int32_t)info.height, fps);
    }
    return atomic_load_explicit(&s_sourceCount, memory_order_acquire) > 0;
}

static NSArray *geistcam_copySources(id receiver, SEL selector, int32_t sourceType) NS_RETURNS_RETAINED {
    return [g_sourceProvider copySourcesWithLoader:^NSArray *(BOOL *shouldCache) {
        NSArray *appleSources = geistcam_copyOriginalSources(
            g_sourceEnumeration,
            receiver,
            selector,
            sourceType
        );
        geistcam_debugf("source enumeration: Apple's source count=%ld", (long)appleSources.count);
        if (!buildGeistCamSources(appleSources)) {
            geistcam_warnf("source enumeration: injected sources unavailable — using Apple's camera sources");
            return appleSources;
        }
        int count = atomic_load_explicit(&s_sourceCount, memory_order_acquire);
        const void *values[GEISTCAM_MAX_SOURCES];
        for (int i = 0; i < count; i++) values[i] = s_sources[i].baseObj;
        CFArrayRef injected = CFArrayCreate(
            kCFAllocatorDefault,
            values,
            count,
            &kCFTypeArrayCallBacks
        );
        *shouldCache = YES;
        geistcam_debugf("source enumeration: returning %d injected source(s)", count);
        return CFBridgingRelease(injected);
    }];
}

static NSArray *geistcam_managerCopySources(id receiver, SEL selector, int32_t sourceType) NS_RETURNS_RETAINED {
    return geistcam_copySources(receiver, selector, sourceType);
}

static CFArrayRef geistcam_FigCaptureSourceCopySources(void) {
    if (g_sourceEnumeration.mode != GeistCamSourceEnumerationModeLegacy) {
        return FigCaptureSourceCopySources ? FigCaptureSourceCopySources() : NULL;
    }
    NSArray *sources = geistcam_copySources(nil, NULL, 0);
    return sources ? CFBridgingRetain(sources) : NULL;
}

BOOL installSourceEnumerationHook(void) {
    if (resolveCMCaptureSymbols() != 0) return NO;
    g_sourceProvider = [GeistCamSerializedSourceProvider new];
    GeistCamLegacyCopySourcesFn legacy = FigCaptureSourceCopySources
        ? FigCaptureSourceCopySources
        : NULL;
    CFStringRef legacyAttributesKey = resolveCFStringConstant(
        "kFigCaptureSourceProperty_AttributesDictionary"
    );
    CFStringRef modernAttributesKey = resolveCFStringConstant(
        "kFigCaptureSourceProperty_Attributes"
    );
    GeistCamSourceAttributes modernAttributes = geistcam_resolveSourceAttributes(
        NSClassFromString(@"FigCaptureSourceAttributes"),
        NULL,
        modernAttributesKey
    );
    if (modernAttributes.mode == GeistCamSourceAttributesModeModernObject) {
        GeistCamSourceEnumeration modernEnumeration = geistcam_installSourceEnumerationHook(
            NSClassFromString(@"FigCaptureSourceManager"),
            NULL,
            (IMP)geistcam_managerCopySources
        );
        if (modernEnumeration.mode == GeistCamSourceEnumerationModeManager) {
            g_sourceAttributes = modernAttributes;
            g_sourceEnumeration = modernEnumeration;
        }
    }
    if (g_sourceEnumeration.mode == GeistCamSourceEnumerationModeUnsupported) {
        GeistCamSourceAttributes legacyAttributes = geistcam_resolveSourceAttributes(
            Nil,
            legacyAttributesKey,
            NULL
        );
        GeistCamSourceEnumeration legacyEnumeration = geistcam_installSourceEnumerationHook(
            Nil,
            legacy,
            (IMP)geistcam_managerCopySources
        );
        if (legacyAttributes.mode == GeistCamSourceAttributesModeLegacyDictionary &&
            legacyEnumeration.mode == GeistCamSourceEnumerationModeLegacy) {
            g_sourceAttributes = legacyAttributes;
            g_sourceEnumeration = legacyEnumeration;
        }
    }
    if (g_sourceEnumeration.mode != GeistCamSourceEnumerationModeUnsupported) {
        g_localizedNameKey = resolveCFStringConstant(
            "kFigCaptureSourceAttributeKey_LocalizedName"
        );
        g_minFrameRateKey = resolveCFStringConstant(
            "kFigCaptureSourceAttributeKey_MinFrameRate"
        );
        g_maxFrameRateKey = resolveCFStringConstant(
            "kFigCaptureSourceAttributeKey_MaxFrameRate"
        );
    }
    switch (g_sourceEnumeration.mode) {
        case GeistCamSourceEnumerationModeManager:
            geistcam_marker("source enumeration: installed FigCaptureSourceManager hook");
            return YES;
        case GeistCamSourceEnumerationModeLegacy:
            geistcam_marker("source enumeration: using FigCaptureSourceCopySources interpose");
            return YES;
        case GeistCamSourceEnumerationModeUnsupported:
            return NO;
    }
}

__attribute__((used))
static struct {
    const void *replacement;
    const void *original;
} _geistcam_interpose_FigCaptureSourceCopySources
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)&geistcam_FigCaptureSourceCopySources,
        (const void *)&FigCaptureSourceCopySources
    };
