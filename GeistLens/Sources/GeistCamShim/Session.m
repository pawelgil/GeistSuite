#import "Session.h"
#import "ActiveFormat.h"
#import "Metadata.h"
#import "OutputBinding.h"
#import "Outputs.h"
#import "PreviewLayer.h"
#import "Server.h"
#import "Util.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSHashTable<AVCaptureSession *> *s_allSessions;
static NSHashTable<AVCaptureSession *> *s_runningSessions;
static NSMutableArray<NSString *> *s_cameraStack;
static NSMutableDictionary<NSString *, NSNumber *> *s_contentionInterruptions;
static NSMutableDictionary<NSString *, NSNumber *> *s_lifecycleInterruptions;
static NSMutableDictionary<NSString *, NSNumber *> *s_manualInterruptions;
static NSMutableDictionary<NSString *, NSNumber *> *s_preconfigurationCameraState;
static NSMutableDictionary<NSString *, NSNumber *> *s_deliveryGenerations;
static NSMutableDictionary<NSString *, dispatch_group_t> *s_deliveryGroups;
static dispatch_queue_t s_interruptionDeliveryQueue;
static NSMutableSet<NSValue *> *s_deallocatingSessions;
static NSMutableDictionary<NSString *, NSDate *> *s_startedAt;
static NSMutableDictionary<NSString *, NSNumber *> *s_startOrders;
static NSUInteger s_nextStartOrder;
static IMP s_origDealloc;
static IMP s_origInit;
static IMP s_origBeginConfiguration;
static IMP s_origStartRunning;
static IMP s_origStopRunning;
static IMP s_origIsRunning;
static IMP s_origIsInterrupted;
static IMP s_origCommitConfiguration;
static IMP s_origAddInput;
static IMP s_origAddInputWithNoConnections;
static IMP s_origRemoveInput;
static IMP s_origPostNotificationNameObjectUserInfo;
static volatile BOOL s_appBackgrounded;
static char kSessionIDKey;

static void reconcileCameraOwnership(void);

static NSString *sessionID(AVCaptureSession *session) {
    NSString *identifier = objc_getAssociatedObject(session, &kSessionIDKey);
    if (identifier) return identifier;
    identifier = [NSUUID UUID].UUIDString.lowercaseString;
    objc_setAssociatedObject(session, &kSessionIDKey, identifier, OBJC_ASSOCIATION_COPY_NONATOMIC);
    return identifier;
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
    NSString *identifier = sessionID(session);
    NSNumber *manual = s_manualInterruptions[identifier];
    if (manual) return manual;
    NSNumber *lifecycle = s_lifecycleInterruptions[identifier];
    if (lifecycle) return lifecycle;
    return s_contentionInterruptions[identifier];
}

BOOL isSessionRunning(AVCaptureSession *session) {
    if (!session) return NO;
    @synchronized (s_allSessions) { return [s_runningSessions containsObject:session]; }
}

BOOL isSessionDelivering(AVCaptureSession *session) {
    if (!isSessionRunning(session)) return NO;
    @synchronized (s_allSessions) { return effectiveInterruptionReason(session) == nil; }
}

uint64_t sessionDeliveryGeneration(AVCaptureSession *session) {
    @synchronized (s_allSessions) {
        return [s_deliveryGenerations[sessionID(session)] unsignedLongLongValue];
    }
}

BOOL beginSessionDelivery(AVCaptureSession *session, uint64_t generation) {
    @synchronized (s_allSessions) {
        NSString *identifier = sessionID(session);
        if (![s_runningSessions containsObject:session]) return NO;
        if (effectiveInterruptionReason(session) != nil) return NO;
        if ([s_deliveryGenerations[identifier] unsignedLongLongValue] != generation) return NO;
        dispatch_group_enter(s_deliveryGroups[identifier]);
        return YES;
    }
}

void endSessionDelivery(AVCaptureSession *session) {
    dispatch_group_t group;
    @synchronized (s_allSessions) { group = s_deliveryGroups[sessionID(session)]; }
    if (group) dispatch_group_leave(group);
}

static void waitForSessionDeliveries(AVCaptureSession *session) {
    dispatch_group_t group;
    @synchronized (s_allSessions) { group = s_deliveryGroups[sessionID(session)]; }
    if (group) dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
}

static void advanceDeliveryGeneration(AVCaptureSession *session) {
    NSString *identifier = sessionID(session);
    uint64_t generation = [s_deliveryGenerations[identifier] unsignedLongLongValue];
    s_deliveryGenerations[identifier] = @(generation + 1);
}

BOOL isAppBackgrounded(void) { return s_appBackgrounded; }

NSArray<AVCaptureSession *> *snapshotRunningSessions(void) {
    @synchronized (s_allSessions) { return [s_runningSessions.allObjects copy]; }
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

static void deliverInterruptionTransitions(NSArray<AVCaptureSession *> *interrupted,
                                           NSInteger reason,
                                           NSArray<AVCaptureSession *> *ended,
                                           BOOL synchronously) {
    void (^deliver)(void) = ^{
        for (AVCaptureSession *session in interrupted) waitForSessionDeliveries(session);
        void (^notify)(void) = ^{
            for (AVCaptureSession *session in interrupted) notifyInterrupted(session, reason);
            for (AVCaptureSession *session in ended) notifyInterruptionEnded(session);
        };
        if ([NSThread isMainThread]) notify();
        else if (synchronously) dispatch_sync(dispatch_get_main_queue(), notify);
        else dispatch_async(dispatch_get_main_queue(), notify);
    };
    if (synchronously && ![NSThread isMainThread]) dispatch_sync(s_interruptionDeliveryQueue, deliver);
    else dispatch_async(s_interruptionDeliveryQueue, deliver);
}

static NSInteger setContentionInterrupted(AVCaptureSession *session, BOOL interrupted) {
    NSString *identifier = sessionID(session);
    __block BOOL wasInterrupted;
    __block BOOL isInterrupted;
    @synchronized (s_allSessions) {
        BOOL alreadyContended = s_contentionInterruptions[identifier] != nil;
        if (alreadyContended == interrupted) return 0;
        wasInterrupted = effectiveInterruptionReason(session) != nil;
        isInterrupted = s_manualInterruptions[identifier] != nil
            || s_lifecycleInterruptions[identifier] != nil
            || interrupted;
    }
    if (wasInterrupted != isInterrupted) [session willChangeValueForKey:@"interrupted"];
    @synchronized (s_allSessions) {
        if (interrupted) {
            s_contentionInterruptions[identifier] = @(AVCaptureSessionInterruptionReasonVideoDeviceInUseByAnotherClient);
        } else {
            [s_contentionInterruptions removeObjectForKey:identifier];
        }
        if (!wasInterrupted && isInterrupted) advanceDeliveryGeneration(session);
    }
    if (wasInterrupted != isInterrupted) [session didChangeValueForKey:@"interrupted"];
    if (!wasInterrupted && isInterrupted) {
        return 1;
    } else if (wasInterrupted && !isInterrupted) {
        return -1;
    }
    return 0;
}

static void reconcileCameraOwnership(void) {
    NSMutableArray<AVCaptureSession *> *interrupted = [NSMutableArray array];
    NSMutableArray<AVCaptureSession *> *ended = [NSMutableArray array];
    NSArray<AVCaptureSession *> *sessions;
    NSString *holder;
    @synchronized (s_allSessions) {
        NSMutableArray<NSString *> *valid = [NSMutableArray array];
        for (NSString *identifier in s_cameraStack) {
            AVCaptureSession *session = sessionForID(identifier);
            if (session && isSessionRunning(session) && sessionHasCamera(session)) [valid addObject:identifier];
        }
        s_cameraStack = valid;
        holder = s_cameraStack.lastObject;
        sessions = s_allSessions.allObjects;
    }
    for (AVCaptureSession *session in sessions) {
        BOOL shouldInterrupt = isSessionRunning(session)
            && sessionHasCamera(session)
            && ![sessionID(session) isEqualToString:holder];
        NSInteger transition = setContentionInterrupted(session, shouldInterrupt);
        if (transition > 0) [interrupted addObject:session];
        if (transition < 0) [ended addObject:session];
    }
    deliverInterruptionTransitions(
        interrupted,
        AVCaptureSessionInterruptionReasonVideoDeviceInUseByAnotherClient,
        ended,
        NO
    );
    serverRecomputeAllSlots();
}

static id swiz_init(id self, SEL _cmd) {
    id session = ((id(*)(id, SEL))s_origInit)(self, _cmd);
    if (session) {
        @synchronized (s_allSessions) {
            [s_allSessions addObject:session];
            NSString *identifier = sessionID(session);
            s_deliveryGenerations[identifier] = @0;
            s_deliveryGroups[identifier] = dispatch_group_create();
        }
    }
    return session;
}

static void swiz_dealloc(__unsafe_unretained id self, SEL _cmd) {
    NSValue *pointer = [NSValue valueWithPointer:(__bridge const void *)self];
    NSString *identifier = [sessionID(self) copy];
    @synchronized (s_allSessions) {
        [s_deallocatingSessions addObject:pointer];
        [s_allSessions removeObject:self];
        [s_runningSessions removeObject:self];
        [s_cameraStack removeObject:identifier];
        [s_contentionInterruptions removeObjectForKey:identifier];
        [s_lifecycleInterruptions removeObjectForKey:identifier];
        [s_manualInterruptions removeObjectForKey:identifier];
        [s_preconfigurationCameraState removeObjectForKey:identifier];
        [s_deliveryGenerations removeObjectForKey:identifier];
        [s_deliveryGroups removeObjectForKey:identifier];
        [s_startedAt removeObjectForKey:identifier];
        [s_startOrders removeObjectForKey:identifier];
    }
    removeOutputBindingsForSessionID(identifier);
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
        s_preconfigurationCameraState[sessionID(self)] = @(sessionHasCamera(self));
    }
}

static void swiz_startRunning(id self, SEL _cmd) {
    @synchronized (s_allSessions) {
        if ([s_runningSessions containsObject:self]) return;
        [s_runningSessions addObject:self];
        NSString *identifier = sessionID(self);
        s_startedAt[identifier] = [NSDate date];
        s_startOrders[identifier] = @(++s_nextStartOrder);
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
    metadataInvalidateDemand();
}

static void swiz_stopRunning(id self, SEL _cmd) {
    @synchronized (s_allSessions) {
        if (![s_runningSessions containsObject:self]) return;
        [s_runningSessions removeObject:self];
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
    BOOL hadCamera;
    BOOL hasCamera = sessionHasCamera(self);
    @synchronized (s_allSessions) {
        NSNumber *prior = s_preconfigurationCameraState[sessionID(self)];
        hadCamera = prior ? prior.boolValue : hasCamera;
        [s_preconfigurationCameraState removeObjectForKey:sessionID(self)];
        if (hadCamera && !hasCamera) advanceDeliveryGeneration(self);
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
        return s_preconfigurationCameraState[sessionID(session)] != nil;
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
        if (hadCamera && !hasCamera) advanceDeliveryGeneration(self);
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
    swizzleMethod(@"AVCaptureSession", @selector(startRunning), (IMP)swiz_startRunning, &s_origStartRunning);
    swizzleMethod(@"AVCaptureSession", @selector(stopRunning), (IMP)swiz_stopRunning, &s_origStopRunning);
    swizzleMethod(@"AVCaptureSession", @selector(isRunning), (IMP)swiz_isRunning, &s_origIsRunning);
    swizzleMethod(@"AVCaptureSession", @selector(isInterrupted), (IMP)swiz_isInterrupted, &s_origIsInterrupted);
    swizzleMethod(@"AVCaptureSession", @selector(commitConfiguration), (IMP)swiz_commitConfiguration, &s_origCommitConfiguration);
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
        if (s_startOrders[identifier]) item[@"startOrder"] = s_startOrders[identifier];
        if (s_startedAt[identifier]) item[@"startedAt"] = @([s_startedAt[identifier] timeIntervalSince1970]);
        [sessions addObject:item];
    }
    [sessions sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"id"] compare:b[@"id"]];
    }];
    NSMutableDictionary *result = [@{ @"runningCount": @(runningCount), @"sessions": sessions } mutableCopy];
    if (holder) result[@"holder"] = holder;
    return result;
}

static NSDictionary *manualInterruption(NSDictionary *request,
                                        BOOL ending,
                                        NSMutableArray<AVCaptureSession *> *interrupted,
                                        NSMutableArray<AVCaptureSession *> *ended) {
    NSString *targetID = request[@"session"];
    NSNumber *reason = request[@"reason"];
    NSMutableArray *affected = [NSMutableArray array];
    NSMutableArray *skipped = [NSMutableArray array];
    __block NSDictionary *payload;
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
        BOOL wasInterrupted;
        BOOL nowInterrupted;
        @synchronized (s_allSessions) {
            if (targetID && !isSessionRunning(session)) {
                skipReason = @"not running";
            } else if (ending) {
                if (!s_manualInterruptions[identifier]) skipReason = @"not manually interrupted";
            } else if (!isSessionRunning(session)) {
                skipReason = @"not running";
            } else if (effectiveInterruptionReason(session)) {
                skipReason = @"already interrupted";
            }
            wasInterrupted = effectiveInterruptionReason(session) != nil;
            nowInterrupted = ending
                ? s_lifecycleInterruptions[identifier] != nil || s_contentionInterruptions[identifier] != nil
                : YES;
        }
        if (skipReason) {
            if (targetID) {
                payload = @{ @"error": [NSString stringWithFormat:@"Camera session %@ is %@", identifier, skipReason] };
                break;
            }
            [skipped addObject:@{ @"session": identifier, @"reason": skipReason }];
            continue;
        }
        if (wasInterrupted != nowInterrupted) [session willChangeValueForKey:@"interrupted"];
        @synchronized (s_allSessions) {
            if (ending) {
                [s_manualInterruptions removeObjectForKey:identifier];
            } else {
                s_manualInterruptions[identifier] = reason;
            }
            if (!wasInterrupted && nowInterrupted) advanceDeliveryGeneration(session);
        }
        if (wasInterrupted != nowInterrupted) [session didChangeValueForKey:@"interrupted"];
        if (!wasInterrupted && nowInterrupted) [interrupted addObject:session];
        if (wasInterrupted && !nowInterrupted) [ended addObject:session];
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
    NSMutableArray<AVCaptureSession *> *interrupted = [NSMutableArray array];
    NSMutableArray<AVCaptureSession *> *ended = [NSMutableArray array];
    void (^work)(void) = ^{
        NSString *command = request[@"command"];
        if ([command isEqualToString:@"status"]) {
            @synchronized (s_allSessions) { payload = @{ @"data": statusPayload() }; }
        } else if ([command isEqualToString:@"interrupt"]) {
            payload = manualInterruption(request, NO, interrupted, ended);
        } else if ([command isEqualToString:@"endInterruption"]) {
            payload = manualInterruption(request, YES, interrupted, ended);
        }
        else payload = @{ @"error": @"Unknown camera control command" };
    };
    if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    if (!payload[@"error"] && (interrupted.count > 0 || ended.count > 0)) {
        deliverInterruptionTransitions(interrupted, [request[@"reason"] integerValue], ended, YES);
    }
    NSMutableDictionary *response = [payload mutableCopy];
    response[@"requestID"] = requestID;
    response[@"ok"] = @(payload[@"error"] == nil);
    return response;
}

static void setBackgroundInterruption(BOOL interrupted) {
    NSMutableArray<AVCaptureSession *> *newlyInterrupted = [NSMutableArray array];
    NSMutableArray<AVCaptureSession *> *ended = [NSMutableArray array];
    NSArray<AVCaptureSession *> *sessions = snapshotRunningSessions();
    for (AVCaptureSession *session in sessions) {
        NSString *identifier = sessionID(session);
        BOOL wasInterrupted;
        BOOL nowInterrupted;
        @synchronized (s_allSessions) {
            wasInterrupted = effectiveInterruptionReason(session) != nil;
            nowInterrupted = s_manualInterruptions[identifier] != nil
                || s_contentionInterruptions[identifier] != nil
                || interrupted;
        }
        if (wasInterrupted != nowInterrupted) [session willChangeValueForKey:@"interrupted"];
        @synchronized (s_allSessions) {
            if (interrupted) {
                s_lifecycleInterruptions[identifier] = @(AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableInBackground);
            } else {
                [s_lifecycleInterruptions removeObjectForKey:identifier];
            }
            if (!wasInterrupted && nowInterrupted) advanceDeliveryGeneration(session);
        }
        if (wasInterrupted != nowInterrupted) [session didChangeValueForKey:@"interrupted"];
        if (!wasInterrupted && nowInterrupted) [newlyInterrupted addObject:session];
        if (wasInterrupted && !nowInterrupted) [ended addObject:session];
    }
    deliverInterruptionTransitions(
        newlyInterrupted,
        AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableInBackground,
        ended,
        NO
    );
}

void installLifecycleObservers(void) {
    NSPointerFunctionsOptions weakPointerOptions = NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality;
    s_allSessions = [NSHashTable hashTableWithOptions:weakPointerOptions];
    s_runningSessions = [NSHashTable hashTableWithOptions:weakPointerOptions];
    s_cameraStack = [NSMutableArray array];
    s_contentionInterruptions = [NSMutableDictionary dictionary];
    s_deallocatingSessions = [NSMutableSet set];
    s_deliveryGenerations = [NSMutableDictionary dictionary];
    s_deliveryGroups = [NSMutableDictionary dictionary];
    s_interruptionDeliveryQueue = dispatch_queue_create("com.noggenfogger.geistcam.interruptions", DISPATCH_QUEUE_SERIAL);
    s_lifecycleInterruptions = [NSMutableDictionary dictionary];
    s_manualInterruptions = [NSMutableDictionary dictionary];
    s_preconfigurationCameraState = [NSMutableDictionary dictionary];
    s_startedAt = [NSMutableDictionary dictionary];
    s_startOrders = [NSMutableDictionary dictionary];
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
