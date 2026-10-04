#import "GCDismissBackdropView.h"

@implementation GCDismissBackdropView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _dismissalEnabled = YES;
        self.isAccessibilityElement = YES;
        self.accessibilityLabel = @"Dismiss broadcast sheet";
        self.accessibilityIdentifier = @"geistcast.dismiss";
    }
    return self;
}

- (UIAccessibilityTraits)accessibilityTraits {
    return UIAccessibilityTraitButton | (self.dismissalEnabled ? 0 : UIAccessibilityTraitNotEnabled);
}

- (BOOL)accessibilityActivate {
    if (!self.dismissalEnabled || !self.dismissalHandler) return NO;
    self.dismissalHandler();
    return YES;
}

- (BOOL)accessibilityPerformEscape {
    return [self accessibilityActivate];
}
@end
