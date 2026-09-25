#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, GeistCameraInterruptionCause) {
    GeistCameraInterruptionCauseContention,
    GeistCameraInterruptionCauseLifecycle,
    GeistCameraInterruptionCauseManual,
};

typedef NS_ENUM(NSInteger, GeistCameraInterruptionTransition) {
    GeistCameraInterruptionTransitionUnchanged,
    GeistCameraInterruptionTransitionBegan,
    GeistCameraInterruptionTransitionEnded,
};

@interface GeistCameraSessionState : NSObject

@property(nonatomic, copy, readonly) NSString *identifier;
@property(nonatomic) BOOL running;
@property(nonatomic, readonly, nullable) NSNumber *interruptionReason;
@property(nonatomic, readonly) uint64_t deliveryGeneration;
@property(nonatomic, strong, readonly) dispatch_group_t deliveryGroup;
@property(nonatomic, readonly) BOOL isConfiguring;
@property(nonatomic, strong, nullable) NSDate *startedAt;
@property(nonatomic, strong, nullable) NSNumber *startOrder;

- (nullable NSNumber *)reasonForCause:(GeistCameraInterruptionCause)cause;
- (void)setReason:(nullable NSNumber *)reason forCause:(GeistCameraInterruptionCause)cause
    NS_SWIFT_NAME(setReason(_:for:));
- (GeistCameraInterruptionTransition)interruptionTransitionForCause:(GeistCameraInterruptionCause)cause
                                                           reason:(nullable NSNumber *)reason
    NS_SWIFT_NAME(interruptionTransition(for:reason:));
- (void)beginConfigurationWithCamera:(BOOL)hasCamera NS_SWIFT_NAME(beginConfiguration(hasCamera:));
- (void)commitConfigurationWithCamera:(BOOL)hasCamera NS_SWIFT_NAME(commitConfiguration(hasCamera:));
- (void)cameraInputsChangedFrom:(BOOL)hadCamera to:(BOOL)hasCamera
    NS_SWIFT_NAME(cameraInputsChanged(from:to:));

@end

NS_ASSUME_NONNULL_END
