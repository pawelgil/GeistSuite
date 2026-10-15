#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface GeistCameraInterruptionDelivery : NSObject
- (instancetype)initWithDeliveryQueue:(dispatch_queue_t)queue;
- (void)enqueueAfterDraining:(dispatch_block_t)drain delivery:(dispatch_block_t)delivery
    NS_SWIFT_NAME(enqueue(afterDraining:delivery:));
- (void)afterPendingTransitions:(dispatch_block_t)effect;
- (void)waitUntilDelivered;
@end
NS_ASSUME_NONNULL_END
