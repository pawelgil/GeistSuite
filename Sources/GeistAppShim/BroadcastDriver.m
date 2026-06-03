#import "BroadcastDriver.h"
#import "PickerUI/BroadcastSheet.h"
#import "ShimLog.h"

@implementation GeistCastBroadcastDriver

+ (instancetype)shared {
    static GeistCastBroadcastDriver *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[GeistCastBroadcastDriver alloc] init]; });
    return s;
}

- (void)tap:(id)sender {
    (void)sender;
    GC_LOG("picker tap intercepted");
    GC_PresentBroadcastSheet();
}

@end
