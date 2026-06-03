#import "RotationCoordinator.h"
#import "Util.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Tracked instances — weak so dealloc auto-removes them.
static NSHashTable<id> *s_coordinators;
static dispatch_queue_t s_coordinatorsQueue;

static double angleForInterfaceOrientation(UIInterfaceOrientation o) {
    switch (o) {
        case UIInterfaceOrientationPortrait:            return 90;
        case UIInterfaceOrientationLandscapeRight:      return 0;
        case UIInterfaceOrientationLandscapeLeft:       return 180;
        case UIInterfaceOrientationPortraitUpsideDown:  return 270;
        default:                                        return 0;
    }
}

static UIInterfaceOrientation currentInterfaceOrientation(void) {
    // Scene-first, then deprecated UIApplication fallback. The legacy API is
    // intentional — non-scene apps and some early-launch paths still rely on
    // it, and it's the only signal available before scene activation.
    UIApplication *app = UIApplication.sharedApplication;
    if (app) {
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive
                && scene.activationState != UISceneActivationStateForegroundInactive) {
                continue;
            }
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            return ws.interfaceOrientation;
        }
    }
    if (app) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        return app.statusBarOrientation;
#pragma clang diagnostic pop
    }
    return UIInterfaceOrientationUnknown;
}

double geistcam_currentCaptureRotationDegrees(void) {
    return angleForInterfaceOrientation(currentInterfaceOrientation());
}

static void fireKVOForOrientationChange(void) {
    __block NSArray *snapshot;
    dispatch_sync(s_coordinatorsQueue, ^{
        snapshot = s_coordinators.allObjects;
    });
    for (id coord in snapshot) {
        [coord willChangeValueForKey:@"videoRotationAngleForHorizonLevelCapture"];
        [coord didChangeValueForKey:@"videoRotationAngleForHorizonLevelCapture"];
        [coord willChangeValueForKey:@"videoRotationAngleForHorizonLevelPreview"];
        [coord didChangeValueForKey:@"videoRotationAngleForHorizonLevelPreview"];
    }
}

static IMP s_origInitWithDevice;
static id swiz_initWithDevicePreviewLayer(id self, SEL _cmd, id device, id previewLayer) {
    typedef id (*Fn)(id, SEL, id, id);
    id result = ((Fn)s_origInitWithDevice)(self, _cmd, device, previewLayer);
    if (result) {
        dispatch_sync(s_coordinatorsQueue, ^{
            [s_coordinators addObject:result];
        });
    }
    return result;
}

// Real iPhone hardware rotates the buffer to match device orientation, leaving
// nothing for the app to do — so RotationCoordinator effectively returns 0.
// The shim emulates the HW rotation in Transform.m using UIScene orientation
// directly; we mirror the iPhone-side contract by also returning 0 here.
static double swiz_videoRotationAngleForHorizonLevelCapture(id self, SEL _cmd) {
    return 0;
}

static double swiz_videoRotationAngleForHorizonLevelPreview(id self, SEL _cmd) {
    return 0;
}

void installRotationCoordinatorSwizzles(void) {
    Class cls = NSClassFromString(@"AVCaptureDeviceRotationCoordinator");
    if (!cls) {
        geistcam_warnf("AVCaptureDeviceRotationCoordinator not found — rotation swizzles skipped");
        return;
    }

    s_coordinators = [NSHashTable weakObjectsHashTable];
    s_coordinatorsQueue = dispatch_queue_create("geistcam.rotation-coordinator", DISPATCH_QUEUE_SERIAL);

    swizzleMethod(@"AVCaptureDeviceRotationCoordinator",
                  @selector(initWithDevice:previewLayer:),
                  (IMP)swiz_initWithDevicePreviewLayer,
                  &s_origInitWithDevice);
    swizzleMethod(@"AVCaptureDeviceRotationCoordinator",
                  @selector(videoRotationAngleForHorizonLevelCapture),
                  (IMP)swiz_videoRotationAngleForHorizonLevelCapture,
                  NULL);
    swizzleMethod(@"AVCaptureDeviceRotationCoordinator",
                  @selector(videoRotationAngleForHorizonLevelPreview),
                  (IMP)swiz_videoRotationAngleForHorizonLevelPreview,
                  NULL);

    // Orientation-change → fire KVO on every tracked coordinator.
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [nc addObserverForName:UIApplicationDidChangeStatusBarOrientationNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) {
        fireKVOForOrientationChange();
    }];
#pragma clang diagnostic pop
    // Scene-based orientation changes don't post a global notification, but
    // the deprecated UIApplication one is still emitted by UIKit in the
    // simulator even for scene-architected apps when interface orientation
    // changes via window rotation.
    geistcam_markerf("RotationCoordinator swizzles installed; UI rotation=%f°",
                     geistcam_currentCaptureRotationDegrees());
}
