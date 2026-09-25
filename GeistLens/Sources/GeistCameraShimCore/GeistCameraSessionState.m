#import "GeistCameraSessionState.h"

@interface GeistCameraSessionState ()
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *reasons;
@property(nonatomic, strong, nullable) NSNumber *preconfigurationCameraState;
@end

@implementation GeistCameraSessionState

- (instancetype)init {
    self = [super init];
    if (self) {
        _identifier = NSUUID.UUID.UUIDString.lowercaseString;
        _deliveryGroup = dispatch_group_create();
        _reasons = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSNumber *)interruptionReason {
    return _reasons[@(GeistCameraInterruptionCauseManual)]
        ?: _reasons[@(GeistCameraInterruptionCauseLifecycle)]
        ?: _reasons[@(GeistCameraInterruptionCauseContention)];
}

- (NSNumber *)reasonForCause:(GeistCameraInterruptionCause)cause {
    return _reasons[@(cause)];
}

- (GeistCameraInterruptionTransition)setReason:(NSNumber *)reason forCause:(GeistCameraInterruptionCause)cause {
    GeistCameraInterruptionTransition transition = [self previewInterruptionTransitionForCause:cause reason:reason];
    _reasons[@(cause)] = reason;
    if (transition == GeistCameraInterruptionTransitionBegan) _deliveryGeneration++;
    return transition;
}

- (GeistCameraInterruptionTransition)previewInterruptionTransitionForCause:(GeistCameraInterruptionCause)cause
                                                           reason:(NSNumber *)reason {
    BOOL interrupted = reason != nil;
    for (NSNumber *otherCause in _reasons) {
        if (otherCause.integerValue != cause) interrupted = YES;
    }
    BOOL wasInterrupted = self.interruptionReason != nil;
    if (wasInterrupted == interrupted) return GeistCameraInterruptionTransitionUnchanged;
    return interrupted ? GeistCameraInterruptionTransitionBegan : GeistCameraInterruptionTransitionEnded;
}

- (BOOL)isConfiguring {
    return _preconfigurationCameraState != nil;
}

- (void)beginConfigurationWithCamera:(BOOL)hasCamera {
    _preconfigurationCameraState = @(hasCamera);
}

- (void)commitConfigurationWithCamera:(BOOL)hasCamera {
    BOOL hadCamera = _preconfigurationCameraState ? _preconfigurationCameraState.boolValue : hasCamera;
    _preconfigurationCameraState = nil;
    [self cameraInputsChangedFrom:hadCamera to:hasCamera];
}

- (void)cameraInputsChangedFrom:(BOOL)hadCamera to:(BOOL)hasCamera {
    if (hadCamera && !hasCamera) _deliveryGeneration++;
}

@end
