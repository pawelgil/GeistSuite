#import "PickerCells.h"

#import <UIKit/UIKit.h>

@implementation GCRecordDotView {
    UIView *_innerDot;
    UILabel *_countdownLabel;
}

- (instancetype)init {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.backgroundColor = [UIColor clearColor];
        self.layer.cornerRadius = 16.5;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.65].CGColor;
        self.layer.borderWidth = 3.3;

        _innerDot = [[UIView alloc] init];
        _innerDot.backgroundColor = [UIColor whiteColor];
        _innerDot.layer.cornerRadius = 6.5;
        _innerDot.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_innerDot];

        _countdownLabel = [[UILabel alloc] init];
        _countdownLabel.textColor = [UIColor whiteColor];
        _countdownLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightRegular];
        _countdownLabel.textAlignment = NSTextAlignmentCenter;
        _countdownLabel.hidden = YES;
        _countdownLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_countdownLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_innerDot.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_innerDot.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_innerDot.widthAnchor constraintEqualToConstant:13],
            [_innerDot.heightAnchor constraintEqualToConstant:13],
            [_countdownLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_countdownLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
    }
    return self;
}

- (void)setIsRecording:(BOOL)isRecording {
    _isRecording = isRecording;
    if (isRecording) {
        self.layer.borderColor = [UIColor colorWithRed:1.0 green:0.15 blue:0.10 alpha:0.80].CGColor;
        _innerDot.backgroundColor = [UIColor colorWithRed:1.0 green:0.15 blue:0.10 alpha:1.0];
    } else {
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.65].CGColor;
        _innerDot.backgroundColor = [UIColor whiteColor];
    }
}

- (void)setCountdownText:(NSString *)text {
    _countdownText = [text copy];
    _countdownLabel.text = text;
    _countdownLabel.hidden = (text == nil);
    _innerDot.hidden = (text != nil);
    if (text != nil) {
        [self animateCountdownNumber];
    }
}

- (void)animateCountdownNumber {
    [_countdownLabel.layer removeAllAnimations];
    _countdownLabel.transform = CGAffineTransformIdentity;
    _countdownLabel.alpha = 1.0;
    [UIView animateWithDuration:0.35
                          delay:0.45
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        self->_countdownLabel.transform = CGAffineTransformMakeScale(0.4, 0.4);
        self->_countdownLabel.alpha = 0;
    } completion:nil];
}
@end


@implementation GCBroadcastAppCell {
    UIImageView *_iconView;
    UILabel *_titleLabel;
    UILabel *_subtitleLabel;
    UIStackView *_titleStack;
    UIImageView *_checkmarkView;
    UIActivityIndicatorView *_activityIndicator;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.20];

        UIView *selected = [[UIView alloc] init];
        selected.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
        self.selectedBackgroundView = selected;

        _iconView = [[UIImageView alloc] init];
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
        _iconView.tintColor = [UIColor whiteColor];
        _iconView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
        _iconView.contentMode = UIViewContentModeCenter;
        _iconView.layer.cornerRadius = 8;
        _iconView.layer.cornerCurve = kCACornerCurveContinuous;
        _iconView.layer.masksToBounds = YES;
        [self.contentView addSubview:_iconView];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.textColor = [UIColor whiteColor];
        _titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];

        _subtitleLabel = [[UILabel alloc] init];
        _subtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
        _subtitleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        _subtitleLabel.hidden = YES;

        _titleStack = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _subtitleLabel]];
        _titleStack.axis = UILayoutConstraintAxisVertical;
        _titleStack.alignment = UIStackViewAlignmentLeading;
        _titleStack.spacing = 2;
        _titleStack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_titleStack];

        _checkmarkView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"]];
        _checkmarkView.translatesAutoresizingMaskIntoConstraints = NO;
        _checkmarkView.tintColor = [UIColor whiteColor];
        _checkmarkView.preferredSymbolConfiguration =
            [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
        [self.contentView addSubview:_checkmarkView];

        _activityIndicator = [[UIActivityIndicatorView alloc]
            initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _activityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
        _activityIndicator.color = [UIColor whiteColor];
        _activityIndicator.hidesWhenStopped = YES;
        [self.contentView addSubview:_activityIndicator];

        [NSLayoutConstraint activateConstraints:@[
            [_iconView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [_iconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:32],
            [_iconView.heightAnchor constraintEqualToConstant:32],
            [_titleStack.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:14],
            [_titleStack.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_checkmarkView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],
            [_checkmarkView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_activityIndicator.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],
            [_activityIndicator.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        ]];
    }
    return self;
}

- (void)configureWithTitle:(NSString *)title
                 iconImage:(UIImage *)iconImage
                isSelected:(BOOL)isSelected
               isRecording:(BOOL)isRecording
              durationText:(NSString *)durationText {
    _titleLabel.text = title;
    if (iconImage) {
        _iconView.image = iconImage;
        _iconView.backgroundColor = [UIColor clearColor];
        _iconView.contentMode = UIViewContentModeScaleAspectFill;
    } else {
        _iconView.image = nil;
        _iconView.backgroundColor = [UIColor systemBlueColor];
        _iconView.contentMode = UIViewContentModeCenter;
    }

    if (isRecording) {
        _subtitleLabel.text = durationText ?: @"00:00";
        _subtitleLabel.hidden = NO;
        _checkmarkView.hidden = YES;
        [_activityIndicator startAnimating];
    } else {
        _subtitleLabel.hidden = YES;
        _checkmarkView.hidden = !isSelected;
        [_activityIndicator stopAnimating];
    }
}
@end
