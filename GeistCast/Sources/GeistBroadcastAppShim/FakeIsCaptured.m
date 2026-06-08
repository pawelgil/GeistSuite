#import "FakeIsCaptured.h"
#import "ShimLog.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdatomic.h>
#include <os/lock.h>

// `UIScreen.main.isCaptured` would normally flip to YES when ReplayKit is
// recording, with UIScreenCapturedDidChangeNotification firing on the
// transition. GeistCast goes from picker-tap straight to spawning the
// extension and never starts real ReplayKit capture, so without help the
// app's isCaptured stays NO and any UI that gates on it (sensitive-view
// dimming, etc.) misbehaves.
//
// On iOS 17+, callers may also check via
// `UITraitCollection.current.sceneCaptureState == .active`. That path is
// independent of -[UIScreen isCaptured] and reads from the trait system,
// so we have to fake the result in three places:
//
//   1. -[UIScreen isCaptured] — direct callers (legacy path).
//   2. -[UITraitCollection sceneCaptureState] — any code that already has
//      a trait collection in hand.
//   3. +[UITraitCollection currentTraitCollection] — Swift's
//      `UITraitCollection.current`, used by `ScreenCaptureObserver`-style
//      checks. We merge a sceneCaptureState=active override into the
//      collection it returns.
//
// The raw UISceneCaptureState values are NOT documented as -1/0/1 in
// Apple's header summaries, but that's what's actually in the compiled
// binaries. UIKitCore's
// `_screenTraitCollectionWithOverridesAppliedFromSceneUISettings` passes
// `[screen isCaptured]` (BOOL: 0 or 1) straight into setSceneCaptureState:,
// and the host Swift binaries we've inspected load `mov w10, #0x1` for
// the `.active` constant. So the runtime mapping is: unspecified=-1,
// inactive=0, active=1. Setting any other value silently breaks every
// consumer.

#define GC_UISceneCaptureStateUnspecified  (-1)
#define GC_UISceneCaptureStateInactive       0
#define GC_UISceneCaptureStateActive         1

static atomic_bool gFakeCaptured = false;
static atomic_bool gMicEnabled = false;
static atomic_bool gMacOSMicAuthorized = true;
static NSDate *gRecordingStartDate = nil;
static os_unfair_lock gRecordingStartDateLock = OS_UNFAIR_LOCK_INIT;

static IMP gOrigIsCapturedIMP = NULL;
static IMP gOrigSceneCaptureStateIMP = NULL;
static IMP gOrigCurrentTraitCollectionIMP = NULL;

BOOL GC_FakeCaptured(void) {
    return atomic_load(&gFakeCaptured);
}

BOOL GC_MicEnabled(void) {
    return atomic_load(&gMicEnabled);
}

void GC_SetMicEnabled(BOOL enabled) {
    atomic_store(&gMicEnabled, enabled);
}

BOOL GC_MacOSMicAuthorized(void) {
    return atomic_load(&gMacOSMicAuthorized);
}

void GC_SetMacOSMicAuthorized(BOOL authorized) {
    BOOL was = atomic_exchange(&gMacOSMicAuthorized, authorized);
    if (was == authorized) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"GCMacOSMicAuthorizationDidChangeNotification"
                          object:nil];
    });
}

void GC_SetRecordingStartDate(NSDate *date) {
    os_unfair_lock_lock(&gRecordingStartDateLock);
    gRecordingStartDate = date;
    os_unfair_lock_unlock(&gRecordingStartDateLock);
}

NSDate *GC_GetRecordingStartDate(void) {
    os_unfair_lock_lock(&gRecordingStartDateLock);
    NSDate *date = gRecordingStartDate;
    os_unfair_lock_unlock(&gRecordingStartDateLock);
    return date;
}

static BOOL swizzledIsCaptured(id self, SEL _cmd) {
    if (atomic_load(&gFakeCaptured)) return YES;
    if (gOrigIsCapturedIMP) {
        return ((BOOL (*)(id, SEL))gOrigIsCapturedIMP)(self, _cmd);
    }
    return NO;
}

static NSInteger swizzledSceneCaptureState(id self, SEL _cmd) {
    if (atomic_load(&gFakeCaptured)) return GC_UISceneCaptureStateActive;
    if (gOrigSceneCaptureStateIMP) {
        return ((NSInteger (*)(id, SEL))gOrigSceneCaptureStateIMP)(self, _cmd);
    }
    return GC_UISceneCaptureStateUnspecified;
}

// Swift's `UITraitCollection.current` maps to the ObjC class method
// `+[UITraitCollection currentTraitCollection]`. We swap the IMP to
// return a merged trait collection whose sceneCaptureState is pinned to
// .active while we're broadcasting; the original collection is preserved
// for every other trait.
static id swizzledCurrentTraitCollection(Class cls, SEL _cmd) {
    typedef id (*Fn)(Class, SEL);
    id orig = gOrigCurrentTraitCollectionIMP
        ? ((Fn)gOrigCurrentTraitCollectionIMP)(cls, _cmd)
        : nil;
    if (!atomic_load(&gFakeCaptured)) return orig;

    SEL withSceneSel = sel_registerName("traitCollectionWithSceneCaptureState:");
    typedef id (*WithSceneFn)(Class, SEL, NSInteger);
    id activeOnly = ((WithSceneFn)objc_msgSend)(cls, withSceneSel,
                                                 (NSInteger)GC_UISceneCaptureStateActive);
    if (!orig) return activeOnly;

    SEL mergeSel = sel_registerName("traitCollectionWithTraitsFromCollections:");
    typedef id (*MergeFn)(Class, SEL, NSArray *);
    return ((MergeFn)objc_msgSend)(cls, mergeSel, @[orig, activeOnly]);
}

void GC_PostScreenCapturedChange(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class scrCls = NSClassFromString(@"UIScreen");
        id mainScreen = nil;
        if (scrCls) {
            mainScreen = ((id (*)(Class, SEL))objc_msgSend)(scrCls,
                                                             sel_registerName("mainScreen"));
        }
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"UIScreenCapturedDidChangeNotification"
                          object:mainScreen];
    });
}

// Sets sceneCaptureState as a UITraitOverride on every connected scene
// and window. View-derived trait collections inherit from the scene, so
// `someView.traitCollection.sceneCaptureState` resolves to .active too —
// not just `UITraitCollection.current`. The instance-method swizzle
// above already covers that read, but applying the override also lets
// UIKit's _UITraitChangeRegistry notify observers and keeps its internal
// trait state consistent with the value we report.
static void GC_ApplySceneCaptureStateOverride(BOOL active) {
    void (^apply)(void) = ^{
        Class appCls = NSClassFromString(@"UIApplication");
        if (!appCls) return;
        id app = ((id (*)(Class, SEL))objc_msgSend)(appCls,
                                                     sel_registerName("sharedApplication"));
        if (!app) return;

        NSArray *scenes = nil;
        @try { scenes = [app valueForKey:@"connectedScenes"]; } @catch (NSException *e) {}
        if (!scenes) return;

        NSInteger value = active ? GC_UISceneCaptureStateActive
                                  : GC_UISceneCaptureStateUnspecified;
        SEL setStateSel = sel_registerName("setSceneCaptureState:");
        SEL traitOverridesSel = sel_registerName("traitOverrides");

        for (id scene in scenes) {
            if ([scene respondsToSelector:traitOverridesSel]) {
                id overrides = ((id (*)(id, SEL))objc_msgSend)(scene, traitOverridesSel);
                if (overrides && [overrides respondsToSelector:setStateSel]) {
                    ((void (*)(id, SEL, NSInteger))objc_msgSend)(overrides, setStateSel, value);
                }
            }
            NSArray *windows = nil;
            @try { windows = [scene valueForKey:@"windows"]; } @catch (NSException *e) {}
            for (id window in windows) {
                if (![window respondsToSelector:traitOverridesSel]) continue;
                id overrides = ((id (*)(id, SEL))objc_msgSend)(window, traitOverridesSel);
                if (!overrides) continue;
                if (![overrides respondsToSelector:setStateSel]) continue;
                ((void (*)(id, SEL, NSInteger))objc_msgSend)(overrides, setStateSel, value);
            }
        }
    };
    if ([NSThread isMainThread]) {
        apply();
    } else {
        dispatch_async(dispatch_get_main_queue(), apply);
    }
}

void GC_SetFakeCaptured(BOOL on) {
    BOOL was = atomic_exchange(&gFakeCaptured, on);
    if (was == on) return;
    GC_LOG("fake UIScreen.isCaptured = %d", (int)on);
    GC_PostScreenCapturedChange();
    GC_ApplySceneCaptureStateOverride(on);
}

void GC_InstallIsCapturedSwizzle(void) {
    Class screenCls = NSClassFromString(@"UIScreen");
    if (screenCls) {
        SEL sel = sel_registerName("isCaptured");
        Method m = class_getInstanceMethod(screenCls, sel);
        if (m) {
            gOrigIsCapturedIMP = method_getImplementation(m);
            method_setImplementation(m, (IMP)swizzledIsCaptured);
            GC_LOG("installed -[UIScreen isCaptured] swizzle");
        }
    }

    Class traitCls = NSClassFromString(@"UITraitCollection");
    if (traitCls) {
        SEL sceneSel = sel_registerName("sceneCaptureState");
        Method sceneM = class_getInstanceMethod(traitCls, sceneSel);
        if (sceneM) {
            gOrigSceneCaptureStateIMP = method_getImplementation(sceneM);
            method_setImplementation(sceneM, (IMP)swizzledSceneCaptureState);
            GC_LOG("installed -[UITraitCollection sceneCaptureState] swizzle");
        }
        SEL currentSel = sel_registerName("currentTraitCollection");
        Method currentM = class_getClassMethod(traitCls, currentSel);
        if (currentM) {
            gOrigCurrentTraitCollectionIMP = method_getImplementation(currentM);
            method_setImplementation(currentM, (IMP)swizzledCurrentTraitCollection);
            GC_LOG("installed +[UITraitCollection currentTraitCollection] swizzle");
        }
    }
}
