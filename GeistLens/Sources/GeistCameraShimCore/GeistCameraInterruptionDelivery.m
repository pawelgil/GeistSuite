#import "GeistCameraInterruptionDelivery.h"

@implementation GeistCameraInterruptionDelivery {
    dispatch_queue_t _orderingQueue;
    dispatch_queue_t _deliveryQueue;
}

- (instancetype)initWithDeliveryQueue:(dispatch_queue_t)queue {
    self = [super init];
    if (self) {
        _orderingQueue = dispatch_queue_create("com.noggenfogger.geistcam.interruptions", DISPATCH_QUEUE_SERIAL);
        _deliveryQueue = queue;
    }
    return self;
}

- (void)enqueueAfterDraining:(dispatch_block_t)drain delivery:(dispatch_block_t)delivery {
    dispatch_async(_orderingQueue, ^{
        drain();
        dispatch_async(self->_deliveryQueue, delivery);
    });
}

- (void)afterPendingTransitions:(dispatch_block_t)effect {
    [self enqueueAfterDraining:^{} delivery:effect];
}

- (void)waitUntilDelivered {
    dispatch_sync(_orderingQueue, ^{
        dispatch_sync(self->_deliveryQueue, ^{});
    });
}
@end
