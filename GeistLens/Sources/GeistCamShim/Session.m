#import "Session.h"
#import "ActiveFormat.h"
#import "Metadata.h"
#import "OutputBinding.h"
#import "PreviewLayer.h"
#import "Server.h"
#import "Util.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>

static NSHashTable *s_runningSessions;
static IMP s_origStartRunning;
static IMP s_origStopRunning;
static IMP s_origIsRunning;
static IMP s_origCommitConfiguration;
static volatile BOOL s_appBackgrounded;

BOOL isSessionRunning(AVCaptureSession *sess) {
    if (!sess) return NO;
    @synchronized (s_runningSessions) { return [s_runningSessions containsObject:sess]; }
}

BOOL isAppBackgrounded(void) { return s_appBackgrounded; }

NSArray<AVCaptureSession *> *snapshotRunningSessions(void) {
    @synchronized (s_runningSessions) { return [[s_runningSessions allObjects] copy]; }
}

// AVF's _isRunning ivar may not flip with our synthesized graph; KVO-gated
// UI would stay disabled. Report YES if we tracked this session.
static BOOL swiz_isRunning(id self, SEL _cmd) {
    if (isSessionRunning(self)) return YES;
    if (s_origIsRunning) return ((BOOL(*)(id, SEL))s_origIsRunning)(self, _cmd);
    return NO;
}

static void swiz_startRunning(id self, SEL _cmd) {
    @synchronized (s_runningSessions) { [s_runningSessions addObject:self]; }
    geistcam_debugf("tracked session %p (start)", self);
    // Skip original — FigCaptureSessionSimulator errors out and posts
    // RuntimeError, which apps surface as "Tap to resume". We own the
    // contract end-to-end.
    [self willChangeValueForKey:@"running"];
    [self didChangeValueForKey:@"running"];
    [self willChangeValueForKey:@"isRunning"];
    [self didChangeValueForKey:@"isRunning"];
    rebuildOutputBindingsForSession(self);
    serverRecomputeAllSlots();
    metadataInvalidateDemand();
}

static void swiz_stopRunning(id self, SEL _cmd) {
    @synchronized (s_runningSessions) { [s_runningSessions removeObject:self]; }
    geistcam_debugf("untracked session %p (stop)", self);
    blankPreviewLayersForSession(self);
    [self willChangeValueForKey:@"running"];
    [self didChangeValueForKey:@"running"];
    [self willChangeValueForKey:@"isRunning"];
    [self didChangeValueForKey:@"isRunning"];
    serverRecomputeAllSlots();
    metadataInvalidateDemand();
    // Skip original — paired with swiz_startRunning's skip.
}

// Original drives Fig's SetConfiguration which errors on the sim. Skip it.
static void swiz_commitConfiguration(id self, SEL _cmd) {
    NSMutableArray *uids = [NSMutableArray array];
    for (AVCaptureInput *input in [self performSelector:@selector(inputs)]) {
        if (![input isKindOfClass:[AVCaptureDeviceInput class]]) continue;
        NSString *uid = ((AVCaptureDeviceInput *)input).device.uniqueID;
        if (uid) [uids addObject:uid];
    }
    geistcam_debugf("commitConfiguration: session=%p inputs=%s", self,
                      [[uids componentsJoinedByString:@","] UTF8String]);
    invalidatePreviewBindings();
    rebuildOutputBindingsForSession((AVCaptureSession *)self);
    activeFormatSnapshotSession((AVCaptureSession *)self);
    serverRecomputeAllSlots();
    metadataInvalidateDemand();
}

void installSessionSwizzles(void) {
    swizzleMethod(@"AVCaptureSession", @selector(startRunning),
                  (IMP)swiz_startRunning, &s_origStartRunning);
    swizzleMethod(@"AVCaptureSession", @selector(stopRunning),
                  (IMP)swiz_stopRunning, &s_origStopRunning);
    swizzleMethod(@"AVCaptureSession", @selector(isRunning),
                  (IMP)swiz_isRunning, &s_origIsRunning);
    swizzleMethod(@"AVCaptureSession", @selector(commitConfiguration),
                  (IMP)swiz_commitConfiguration, &s_origCommitConfiguration);
}

// _setInterrupted:withReason:interruptor: deadlocks sim UI on iOS 26.x;
// post the public notifications directly instead.
static void postInterruptedNotifications(int reason) {
    NSArray *sessions;
    @synchronized (s_runningSessions) { sessions = [[s_runningSessions allObjects] copy]; }
    NSDictionary *userInfo = @{ AVCaptureSessionInterruptionReasonKey: @(reason) };
    for (id session in sessions) {
        [[NSNotificationCenter defaultCenter] postNotificationName:AVCaptureSessionWasInterruptedNotification
                                                            object:session
                                                          userInfo:userInfo];
    }
}

static void postInterruptionEndedNotifications(void) {
    NSArray *sessions;
    @synchronized (s_runningSessions) { sessions = [[s_runningSessions allObjects] copy]; }
    for (id session in sessions) {
        [[NSNotificationCenter defaultCenter] postNotificationName:AVCaptureSessionInterruptionEndedNotification
                                                            object:session];
    }
}

static void geistcamInterruptAllSessions(int reason, NSString *interruptor) {
    postInterruptedNotifications(reason);
}

static void geistcamResumeAllSessions(void) {
    postInterruptionEndedNotifications();
}

void installLifecycleObservers(void) {
    s_runningSessions = [NSHashTable weakObjectsHashTable];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                      object:nil queue:nil
                                                  usingBlock:^(NSNotification *n) {
        s_appBackgrounded = YES;
        // Sync post inside UIKit's lifecycle chain freezes sim UI on iOS 26.x.
        dispatch_async(dispatch_get_main_queue(), ^{
            geistcamInterruptAllSessions((int)AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableInBackground,
                                          @"sim.background");
        });
        serverRecomputeAllSlots();
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
                                                      object:nil queue:nil
                                                  usingBlock:^(NSNotification *n) {
        s_appBackgrounded = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            geistcamResumeAllSessions();
        });
        serverRecomputeAllSlots();
    }];
}

__attribute__((visibility("default")))
void SimulatorCameraTriggerInterruption(int reason, const char *interruptor) {
    NSString *who = interruptor ? [NSString stringWithUTF8String:interruptor] : nil;
    geistcamInterruptAllSessions(reason, who);
}

__attribute__((visibility("default")))
void SimulatorCameraResumeFromInterruption(void) {
    geistcamResumeAllSessions();
}
