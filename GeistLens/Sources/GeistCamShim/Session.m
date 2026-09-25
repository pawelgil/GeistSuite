#import "Session.h"
#import "ActiveFormat.h"
#import "Metadata.h"
#import "OutputBinding.h"
#import "Outputs.h"
#import "PreviewLayer.h"
#import "Server.h"
#import "Util.h"
#import "GeistCameraSessionState.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSHashTable<AVCaptureSession *> *s_allSessions;
static NSMutableArray<NSString *> *s_cameraStack;
static dispatch_queue_t s_interruptionDeliveryQueue;
static NSMutableSet<NSValue *> *s_deallocatingSessions;
static NSUInteger s_nextStartOrder;
static IMP s_origDealloc;
static IMP s_origInit;
static IMP s_origBeginConfiguration;
static IMP s_origIsRunning;
static IMP s_origIsInterrupted;
static IMP s_origAddInput;
static IMP s_origAddInputWithNoConnections;
static IMP s_origRemoveInput;
static IMP s_origPostNotificationNameObjectUserInfo;
static volatile BOOL s_appBackgrounded;
static char kSessionStateKey;

static void reconcileCameraOwnership(void);
static void setBackgroundInterruption(BOOL interrupted);

static GeistCameraSessionState *sessionState(AVCaptureSession *session) {
    return objc_getAssociatedObject(session, &kSessionStateKey);
}

static NSString *sessionID(AVCaptureSession *session) {
    return sessionState(session).identifier;
}

NSString *cameraSessionIdentifier(AVCaptureSession *session) {
    return sessionID(session);
}

BOOL isCameraSessionDeallocating(AVCaptureSession *session) {
    NSValue *pointer = [NSValue valueWithPointer:(__bridge const void *)session];
    @synchronized (s_allSessions) { return [s_deallocatingSessions containsObject:pointer]; }
}

static AVCaptureSession *sessionForID(NSString *identifier) {
    for (AVCaptureSession *session in s_allSessions.allObjects) {
        if ([sessionID(session) isEqualToString:identifier]) return session;
    }
    return nil;
}

static BOOL sessionHasCamera(AVCaptureSession *session) {
    for (AVCaptureInput *input in session.inputs) {
        if (![input isKindOfClass:[AVCaptureDeviceInput class]]) continue;
        AVCaptureDevice *device = ((AVCaptureDeviceInput *)input).device;
        if ([device hasMediaType:AVMediaTypeVideo]) return YES;
    }
    return NO;
}

static NSNumber *effectiveInterruptionReason(AVCaptureSession *session) {
    return sessionState(session).interruptionReason;
}

BOOL isSessionRunning(AVCaptureSession *session) {
    if (!session) return NO;
    @synchronized (s_allSessions) { return sessionState(session).running; }
}

BOOL isSessionDelivering(AVCaptureSession *session) {
    if (!isSessionRunning(session)) return NO;
    @synchronized (s_allSessions) { return effectiveInterruptionReason(session) == nil; }
}

uint64_t sessionDeliveryGeneration(AVCaptureSession *session) {
    @synchronized (s_allSessions) {
        return sessionState(session).deliveryGeneration;
    }
}

BOOL beginSessionDelivery(AVCaptureSession *session, uint64_t generation) {
    @synchronized (s_allSessions) {
        GeistCameraSessionState *state = sessionState(session);
        if (!state.running || state.interruptionReason != nil) return NO;
        if (state.deliveryGeneration != generation) return NO;
        dispatch_group_enter(state.deliveryGroup);
        return YES;
    }
}

void endSessionDelivery(AVCaptureSession *session) {
    dispatch_group_t group;
    @synchronized (s_allSessions) { group = sessionState(session).deliveryGroup; }
    if (group) dispatch_group_leave(group);
}

static void waitForSessionDeliveries(AVCaptureSession *session) {
    dispatch_group_t group;
    @synchronized (s_allSessions) { group = sessionState(session).deliveryGroup; }
    if (group) dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
}

BOOL isAppBackgrounded(void) { return s_appBackgrounded; }

NSArray<AVCaptureSession *> *snapshotRunningSessions(void) {
    @synchronized (s_allSessions) {
        NSMutableArray *running = [NSMutableArray array];
        for (AVCaptureSession *session in s_allSessions.allObjects) {
            if (sessionState(session).running) [running addObject:session];
        }
        return running;
    }
}

static void notifyInterrupted(AVCaptureSession *session, NSInteger reason) {
    interruptMovieFileOutputsForSession(session);
    NSDictionary *userInfo = @{ AVCaptureSessionInterruptionReasonKey: @(reason) };
    [[NSNotificationCenter defaultCenter] postNotificationName:AVCaptureSessionWasInterruptedNotification
                                                        object:session
                                                      userInfo:userInfo];
}

static void notifyInterruptionEnded(AVCaptureSession *session) {
    [[NSNotificationCenter defaultCenter] postNotificationName:AVCaptureSessionInterruptionEndedNotification
                                                        object:session];
}

// Call while holding s_allSessions so delivery order matches commit order.
static void enqueueCommittedInterruptionTransition(
    AVCaptureSession *session, GeistCameraInterruptionTransition transition, NSNumber *reason
) {
    if (transition == GeistCameraInterruptionTransitionUnchanged) return;
    dispatch_async(s_interruptionDeliveryQueue, ^{
        if (transition == GeistCameraInterruptionTransitionBegan) waitForSessionDeliveries(session);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (transition == GeistCameraInterruptionTransitionBegan) notifyInterrupted(session, reason.integerValue);
            else notifyInterruptionEnded(session);
        });
    });
}

static void waitForInterruptionNotifications(void) {
    if ([NSThread isMainThread]) return;
    dispatch_sync(s_interruptionDeliveryQueue, ^{
        dispatch_sync(dispatch_get_main_queue(), ^{});
    });
}

static GeistCameraInterruptionTransition updateInterruptionReason(
    AVCaptureSession *session, GeistCameraInterruptionCause cause, NSNumber *(^currentReason)(void)
) {
    for (;;) {
        GeistCameraInterruptionTransition preview;
        @synchronized (s_allSessions) {
            preview = [sessionState(session) previewInterruptionTransitionForCause:cause reason:currentReason()];
        }
        BOOL changes = preview != GeistCameraInterruptionTransitionUnchanged;
        if (changes) [session willChangeValueForKey:@"interrupted"];
        BOOL committed = NO;
        GeistCameraInterruptionTransition transition = GeistCameraInterruptionTransitionUnchanged;
        @synchronized (s_allSessions) {
            NSNumber *reason = currentReason();
            GeistCameraSessionState *state = sessionState(session);
            if ([state previewInterruptionTransitionForCause:cause reason:reason] == preview) {
                transition = [state setReason:reason forCause:cause];
                enqueueCommittedInterruptionTransition(session, transition, reason);
                committed = YES;
            }
        }
        if (changes) [session didChangeValueForKey:@"interrupted"];
        if (committed) return transition;
    }
}

static GeistCameraInterruptionTransition setInterruptionReason(
    AVCaptureSession *session, GeistCameraInterruptionCause cause, NSNumber *reason
) {
    return updateInterruptionReason(session, cause, ^NSNumber *{ return reason; });
}

static NSNumber *cameraContentionReason(AVCaptureSession *session) {
    BOOL shouldInterrupt = isSessionRunning(session)
        && sessionHasCamera(session)
        && ![sessionID(session) isEqualToString:s_cameraStack.lastObject];
    return shouldInterrupt ? @(AVCaptureSessionInterruptionReasonVideoDeviceInUseByAnotherClient) : nil;
}

static void reconcileCameraOwnership(void) {
    NSArray<AVCaptureSession *> *sessions;
    @synchronized (s_allSessions) {
        NSMutableArray<NSString *> *valid = [NSMutableArray array];
        for (NSString *identifier in s_cameraStack) {
            AVCaptureSession *session = sessionForID(identifier);
            if (session && isSessionRunning(session) && sessionHasCamera(session)) [valid addObject:identifier];
        }
        s_cameraStack = valid;
        sessions = s_allSessions.allObjects;
    }
    for (AVCaptureSession *session in sessions) {
        updateInterruptionReason(
            session, GeistCameraInterruptionCauseContention,
            ^NSNumber *{ return cameraContentionReason(session); });
    }
    serverRecomputeAllSlots();
}

static id swiz_init(id self, SEL _cmd) {
    id session = ((id(*)(id, SEL))s_origInit)(self, _cmd);
    if (session) {
        @synchronized (s_allSessions) {
            objc_setAssociatedObject(session, &kSessionStateKey, [GeistCameraSessionState new],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [s_allSessions addObject:session];
        }
    }
    return session;
}

static void swiz_dealloc(__unsafe_unretained id self, SEL _cmd) {
    NSValue *pointer = [NSValue valueWithPointer:(__bridge const void *)self];
    NSString *identifier = [sessionID(self) copy];
    @synchronized (s_allSessions) {
        [s_deallocatingSessions addObject:pointer];
        sessionState(self).running = NO;
        [s_allSessions removeObject:self];
        if (identifier) [s_cameraStack removeObject:identifier];
    }
    if (identifier) removeOutputBindingsForSessionID(identifier);
    reconcileCameraOwnership();
    ((void(*)(id, SEL))s_origDealloc)(self, _cmd);
    @synchronized (s_allSessions) { [s_deallocatingSessions removeObject:pointer]; }
}

static BOOL swiz_isRunning(id self, SEL _cmd) {
    if (isCameraSessionDeallocating(self)) return NO;
    if (isSessionRunning(self)) return YES;
    if (s_origIsRunning) return ((BOOL(*)(id, SEL))s_origIsRunning)(self, _cmd);
    return NO;
}

static BOOL swiz_isInterrupted(id self, SEL _cmd) {
    if (isCameraSessionDeallocating(self)) return NO;
    @synchronized (s_allSessions) {
        if (effectiveInterruptionReason(self)) return YES;
    }
    if (s_origIsInterrupted) return ((BOOL(*)(id, SEL))s_origIsInterrupted)(self, _cmd);
    return NO;
}

static void swiz_beginConfiguration(id self, SEL _cmd) {
    ((void(*)(id, SEL))s_origBeginConfiguration)(self, _cmd);
    @synchronized (s_allSessions) {
        [sessionState(self) beginConfigurationWithCamera:sessionHasCamera(self)];
    }
}

static void swiz_startRunning(id self, SEL _cmd) {
    @synchronized (s_allSessions) {
        GeistCameraSessionState *state = sessionState(self);
        if (state.running) return;
        state.running = YES;
        NSString *identifier = sessionID(self);
        state.startedAt = [NSDate date];
        state.startOrder = @(++s_nextStartOrder);
        if (sessionHasCamera(self)) {
            [s_cameraStack removeObject:identifier];
            [s_cameraStack addObject:identifier];
        }
    }
    geistcam_debugf("tracked session %p (start)", self);
    [self willChangeValueForKey:@"running"];
    [self didChangeValueForKey:@"running"];
    [self willChangeValueForKey:@"isRunning"];
    [self didChangeValueForKey:@"isRunning"];
    rebuildOutputBindingsForSession(self);
    reconcileCameraOwnership();
    if (s_appBackgrounded) setBackgroundInterruption(YES);
    metadataInvalidateDemand();
}

static void swiz_stopRunning(id self, SEL _cmd) {
    @synchronized (s_allSessions) {
        GeistCameraSessionState *state = sessionState(self);
        if (!state.running) return;
        state.running = NO;
        [s_cameraStack removeObject:sessionID(self)];
    }
    geistcam_debugf("untracked session %p (stop)", self);
    blankPreviewLayersForSession(self);
    [self willChangeValueForKey:@"running"];
    [self didChangeValueForKey:@"running"];
    [self willChangeValueForKey:@"isRunning"];
    [self didChangeValueForKey:@"isRunning"];
    reconcileCameraOwnership();
    metadataInvalidateDemand();
}

static void swiz_commitConfiguration(id self, SEL _cmd) {
    if (isCameraSessionDeallocating(self)) return;
    BOOL hasCamera = sessionHasCamera(self);
    @synchronized (s_allSessions) {
        [sessionState(self) commitConfigurationWithCamera:hasCamera];
    }
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
    @synchronized (s_allSessions) {
        NSString *identifier = sessionID(self);
        if (isSessionRunning(self) && sessionHasCamera(self) && ![s_cameraStack containsObject:identifier]) {
            [s_cameraStack addObject:identifier];
        }
        if (!sessionHasCamera(self)) [s_cameraStack removeObject:identifier];
    }
    reconcileCameraOwnership();
    metadataInvalidateDemand();
}

static BOOL isSessionBeingConfigured(AVCaptureSession *session) {
    @synchronized (s_allSessions) {
        return sessionState(session).isConfiguring;
    }
}

static void reconcileAddedInput(AVCaptureSession *session) {
    if (isCameraSessionDeallocating(session)) return;
    if (isSessionBeingConfigured(session)) return;
    if (!isSessionRunning(session)) return;
    @synchronized (s_allSessions) {
        NSString *identifier = sessionID(session);
        if (sessionHasCamera(session) && ![s_cameraStack containsObject:identifier]) {
            [s_cameraStack addObject:identifier];
        }
    }
    rebuildOutputBindingsForSession(session);
    reconcileCameraOwnership();
}

static void swiz_addInput(id self, SEL _cmd, AVCaptureInput *input) {
    ((void(*)(id, SEL, AVCaptureInput *))s_origAddInput)(self, _cmd, input);
    reconcileAddedInput(self);
}

static void swiz_addInputWithNoConnections(id self, SEL _cmd, AVCaptureInput *input) {
    ((void(*)(id, SEL, AVCaptureInput *))s_origAddInputWithNoConnections)(self, _cmd, input);
    reconcileAddedInput(self);
}

static void swiz_removeInput(id self, SEL _cmd, AVCaptureInput *input) {
    BOOL hadCamera = sessionHasCamera(self);
    ((void(*)(id, SEL, AVCaptureInput *))s_origRemoveInput)(self, _cmd, input);
    if (isCameraSessionDeallocating(self)) return;
    if (isSessionBeingConfigured(self)) return;
    @synchronized (s_allSessions) {
        BOOL hasCamera = sessionHasCamera(self);
        [sessionState(self) cameraInputsChangedFrom:hadCamera to:hasCamera];
        if (!hasCamera) [s_cameraStack removeObject:sessionID(self)];
    }
    rebuildOutputBindingsForSession(self);
    reconcileCameraOwnership();
}

static void swiz_postNotificationNameObjectUserInfo(id self, SEL _cmd, NSString *name, id object, NSDictionary *userInfo) {
    if ([name isEqualToString:AVCaptureSessionRuntimeErrorNotification]) return;
    if (s_origPostNotificationNameObjectUserInfo) {
        ((void(*)(id, SEL, NSString *, id, NSDictionary *))s_origPostNotificationNameObjectUserInfo)(self, _cmd, name, object, userInfo);
    }
}

void installSessionSwizzles(void) {
    swizzleMethod(@"AVCaptureSession", sel_registerName("dealloc"), (IMP)swiz_dealloc, &s_origDealloc);
    swizzleMethod(@"AVCaptureSession", @selector(init), (IMP)swiz_init, &s_origInit);
    swizzleMethod(@"AVCaptureSession", @selector(beginConfiguration), (IMP)swiz_beginConfiguration, &s_origBeginConfiguration);
    swizzleMethod(@"AVCaptureSession", @selector(startRunning), (IMP)swiz_startRunning, NULL);
    swizzleMethod(@"AVCaptureSession", @selector(stopRunning), (IMP)swiz_stopRunning, NULL);
    swizzleMethod(@"AVCaptureSession", @selector(isRunning), (IMP)swiz_isRunning, &s_origIsRunning);
    swizzleMethod(@"AVCaptureSession", @selector(isInterrupted), (IMP)swiz_isInterrupted, &s_origIsInterrupted);
    swizzleMethod(@"AVCaptureSession", @selector(commitConfiguration), (IMP)swiz_commitConfiguration, NULL);
    swizzleMethod(@"AVCaptureSession", @selector(addInput:), (IMP)swiz_addInput, &s_origAddInput);
    swizzleMethod(@"AVCaptureSession", @selector(addInputWithNoConnections:),
                  (IMP)swiz_addInputWithNoConnections, &s_origAddInputWithNoConnections);
    swizzleMethod(@"AVCaptureSession", @selector(removeInput:), (IMP)swiz_removeInput, &s_origRemoveInput);
    swizzleMethod(@"NSNotificationCenter", @selector(postNotificationName:object:userInfo:),
                  (IMP)swiz_postNotificationNameObjectUserInfo, &s_origPostNotificationNameObjectUserInfo);
}

static NSArray *inputNames(AVCaptureSession *session) {
    NSMutableArray *names = [NSMutableArray array];
    for (AVCaptureInput *input in session.inputs) {
        if (![input isKindOfClass:[AVCaptureDeviceInput class]]) continue;
        AVCaptureDevice *device = ((AVCaptureDeviceInput *)input).device;
        if ([device hasMediaType:AVMediaTypeAudio]) [names addObject:@"microphone"];
        if ([device hasMediaType:AVMediaTypeVideo]) {
            [names addObject:device.position == AVCaptureDevicePositionFront ? @"frontCamera" : @"backCamera"];
        }
    }
    return names;
}

static NSDictionary *statusPayload(void) {
    NSMutableArray *sessions = [NSMutableArray array];
    NSString *holder = s_cameraStack.lastObject;
    NSUInteger runningCount = 0;
    for (AVCaptureSession *session in s_allSessions.allObjects) {
        NSString *identifier = sessionID(session);
        BOOL running = isSessionRunning(session);
        if (running) runningCount++;
        NSNumber *reason = effectiveInterruptionReason(session);
        NSMutableArray *outputs = [NSMutableArray array];
        for (AVCaptureOutput *output in session.outputs) [outputs addObject:NSStringFromClass(output.class)];
        NSMutableDictionary *item = [@{
            @"id": identifier,
            @"isRunning": @(running),
            @"isInterrupted": reason ? @YES : @NO,
            @"holdsCamera": @([identifier isEqualToString:holder]),
            @"inputs": inputNames(session),
            @"outputs": outputs,
        } mutableCopy];
        if (reason) item[@"interruptionReason"] = reason;
        GeistCameraSessionState *state = sessionState(session);
        if (state.startOrder) item[@"startOrder"] = state.startOrder;
        if (state.startedAt) item[@"startedAt"] = @(state.startedAt.timeIntervalSince1970);
        [sessions addObject:item];
    }
    [sessions sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"id"] compare:b[@"id"]];
    }];
    NSMutableDictionary *result = [@{ @"runningCount": @(runningCount), @"sessions": sessions } mutableCopy];
    if (holder) result[@"holder"] = holder;
    return result;
}

static NSDictionary *manualInterruption(NSDictionary *request, BOOL ending, BOOL *enqueuedNotification) {
    NSString *targetID = request[@"session"];
    NSNumber *reason = request[@"reason"];
    NSMutableArray *affected = [NSMutableArray array];
    NSMutableArray *skipped = [NSMutableArray array];
    NSDictionary *payload;
    NSArray *targets;
    @synchronized (s_allSessions) {
        targets = targetID ? @[ sessionForID(targetID) ?: NSNull.null ] : s_allSessions.allObjects;
    }
    for (id value in targets) {
        if (value == NSNull.null) {
            payload = @{ @"error": [NSString stringWithFormat:@"Camera session %@ was not found", targetID] };
            break;
        }
        AVCaptureSession *session = value;
        NSString *identifier = sessionID(session);
        NSString *skipReason;
        @synchronized (s_allSessions) {
            if (targetID && !isSessionRunning(session)) {
                skipReason = @"not running";
            } else if (ending) {
                if (![sessionState(session) reasonForCause:GeistCameraInterruptionCauseManual]) {
                    skipReason = @"not manually interrupted";
                }
            } else if (!isSessionRunning(session)) {
                skipReason = @"not running";
            } else if (effectiveInterruptionReason(session)) {
                skipReason = @"already interrupted";
            }
        }
        if (skipReason) {
            if (targetID) {
                payload = @{ @"error": [NSString stringWithFormat:@"Camera session %@ is %@", identifier, skipReason] };
                break;
            }
            [skipped addObject:@{ @"session": identifier, @"reason": skipReason }];
            continue;
        }
        GeistCameraInterruptionTransition transition = setInterruptionReason(
            session, GeistCameraInterruptionCauseManual, ending ? nil : reason);
        if (transition != GeistCameraInterruptionTransitionUnchanged) *enqueuedNotification = YES;
        [affected addObject:identifier];
    }
    if (!payload) {
        payload = affected.count == 0
            ? @{ @"error": ending ? @"No manually interrupted camera sessions" : @"No running, non-interrupted camera sessions" }
            : @{ @"data": @{ @"affected": affected, @"skipped": skipped } };
    }
    serverRecomputeAllSlots();
    return payload;
}

NSDictionary *cameraHandleControlRequest(NSDictionary *request) {
    NSString *requestID = request[@"requestID"] ?: @"";
    __block NSDictionary *payload;
    __block BOOL enqueuedNotification = NO;
    NSString *command = request[@"command"];
    void (^work)(void) = ^{
        if ([command isEqualToString:@"status"]) {
            @synchronized (s_allSessions) { payload = @{ @"data": statusPayload() }; }
        } else if ([command isEqualToString:@"interrupt"]) {
            payload = manualInterruption(request, NO, &enqueuedNotification);
        } else if ([command isEqualToString:@"endInterruption"]) {
            payload = manualInterruption(request, YES, &enqueuedNotification);
        }
        else payload = @{ @"error": @"Unknown camera control command" };
    };
    if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    if (!payload[@"error"] && enqueuedNotification) {
        waitForInterruptionNotifications();
    }
    NSMutableDictionary *response = [payload mutableCopy];
    response[@"requestID"] = requestID;
    response[@"ok"] = @(payload[@"error"] == nil);
    return response;
}

static void setBackgroundInterruption(BOOL interrupted) {
    NSArray<AVCaptureSession *> *sessions;
    @synchronized (s_allSessions) { sessions = s_allSessions.allObjects; }
    for (AVCaptureSession *session in sessions) {
        if (interrupted && !isSessionRunning(session)) continue;
        NSNumber *reason = interrupted
            ? @(AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableInBackground) : nil;
        setInterruptionReason(
            session, GeistCameraInterruptionCauseLifecycle, reason);
    }
}

void installLifecycleObservers(void) {
    NSPointerFunctionsOptions weakPointerOptions = NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality;
    s_allSessions = [NSHashTable hashTableWithOptions:weakPointerOptions];
    s_cameraStack = [NSMutableArray array];
    s_deallocatingSessions = [NSMutableSet set];
    s_interruptionDeliveryQueue = dispatch_queue_create("com.noggenfogger.geistcam.interruptions", DISPATCH_QUEUE_SERIAL);
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                      object:nil queue:nil usingBlock:^(NSNotification *note) {
        s_appBackgrounded = YES;
        dispatch_async(dispatch_get_main_queue(), ^{ setBackgroundInterruption(YES); });
        serverRecomputeAllSlots();
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
                                                      object:nil queue:nil usingBlock:^(NSNotification *note) {
        s_appBackgrounded = NO;
        dispatch_async(dispatch_get_main_queue(), ^{ setBackgroundInterruption(NO); });
        serverRecomputeAllSlots();
    }];
}

__attribute__((visibility("default")))
void SimulatorCameraTriggerInterruption(int reason, const char *interruptor) {
    NSDictionary *request = @{ @"requestID": @"legacy", @"command": @"interrupt", @"reason": @(reason) };
    cameraHandleControlRequest(request);
}

__attribute__((visibility("default")))
void SimulatorCameraResumeFromInterruption(void) {
    NSDictionary *request = @{ @"requestID": @"legacy", @"command": @"endInterruption" };
    cameraHandleControlRequest(request);
}
