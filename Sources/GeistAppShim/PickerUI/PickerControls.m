#import "PickerControls.h"

#import <UIKit/UIKit.h>

@implementation GCFooterButton {
    UILabel *_label;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _label = [[UILabel alloc] init];
        _label.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
        _label.textColor = [UIColor whiteColor];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.userInteractionEnabled = NO;
        _label.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_label];
        [NSLayoutConstraint activateConstraints:@[
            [_label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_label.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_label.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        ]];
    }
    return self;
}

- (void)setTitle:(NSString *)title { _label.text = title; }

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.backgroundColor = highlighted
        ? [UIColor colorWithWhite:1.0 alpha:0.20]
        : [UIColor clearColor];
}
@end


@implementation GCCircleGlassButton {
    UIVisualEffectView *_glass;
    UIImageView *_iconView;
}

@synthesize iconView = _iconView;

- (instancetype)initWithSize:(CGFloat)size {
    if ((self = [super initWithFrame:CGRectZero])) {
        UIGlassEffect *effect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleClear];
        effect.tintColor = [UIColor colorWithWhite:1.0 alpha:0.18];
        _glass = [[UIVisualEffectView alloc] initWithEffect:effect];
        _glass.translatesAutoresizingMaskIntoConstraints = NO;
        _glass.userInteractionEnabled = NO;
        _glass.layer.cornerRadius = size / 2.0;
        _glass.layer.cornerCurve = kCACornerCurveContinuous;
        _glass.layer.masksToBounds = YES;
        _glass.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.32].CGColor;
        _glass.layer.borderWidth = 1;
        [self addSubview:_glass];

        _iconView = [[UIImageView alloc] init];
        _iconView.contentMode = UIViewContentModeCenter;
        _iconView.userInteractionEnabled = NO;
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
        [_glass.contentView addSubview:_iconView];

        _onTint = [UIColor whiteColor];
        _offTint = [UIColor colorWithWhite:0.5 alpha:1.0];

        [NSLayoutConstraint activateConstraints:@[
            [self.widthAnchor constraintEqualToConstant:size],
            [self.heightAnchor constraintEqualToConstant:size],
            [_glass.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_glass.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_glass.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_glass.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_iconView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_iconView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
    }
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [self refreshBackground];
}

- (void)setIsOn:(BOOL)isOn {
    _isOn = isOn;
    [self refreshBackground];
    _iconView.tintColor = isOn ? _onTint : _offTint;
}

- (void)refreshBackground {
    static UIColor *activeRed = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        activeRed = [UIColor colorWithRed:1.0 green:0.15 blue:0.10 alpha:1.0];
    });
    if (_isOn) {
        _glass.contentView.backgroundColor = self.highlighted
            ? [activeRed colorWithAlphaComponent:0.85]
            : activeRed;
    } else {
        _glass.contentView.backgroundColor = self.highlighted
            ? [UIColor colorWithWhite:1.0 alpha:0.12]
            : [UIColor clearColor];
    }
}
@end
