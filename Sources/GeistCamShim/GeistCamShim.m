// Transparent camera emulation. Mints synthetic FigCaptureSource instances
// so AVF device-discovery sees back/front cameras + microphone; everything
// downstream (outputs, preview, recording) is owned by the AVF-level swizzles.
// FigCaptureSession is intentionally NOT patched — we never let it set up.

#import <Foundation/Foundation.h>
#import "AssetWriterSwizzles.h"
#import "Metadata.h"
#import "Outputs.h"
#import "PreviewLayer.h"
#import "RotationCoordinator.h"
#import "Server.h"
#import "Session.h"
#import "Util.h"

static void installAVFSwizzles(void) {
    installSessionSwizzles();
    installPreviewSwizzles();
    installMovieFileSwizzles();
    installDataOutputSwizzles();
    installPhotoSwizzles();
    installMetadataSwizzles();
    installCapabilitySwizzles();
    installAssetWriterSwizzles();
    installRotationCoordinatorSwizzles();
}

// Skip swizzle install in non-camera processes — when GeistLens auto-injects
// the dylib into every simulator-spawned process, SpringBoard / ReportCrash /
// etc. shouldn't pay the cost.
static BOOL hostAppHasCameraIntent(void) {
    return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSCameraUsageDescription"] != nil;
}

__attribute__((constructor))
static void geistcam_init(void) {
    if (!hostAppHasCameraIntent()) return;
    geistcam_marker("dylib loaded");
    installAVFSwizzles();
    installLifecycleObservers();
    if (!startServerIfConfigured()) {
        geistcam_warnf("no socket path — set GEISTCAM_SOCKET, or set "
                         "SIMULATOR_UDID + run inside a real simulator app");
    }
}
