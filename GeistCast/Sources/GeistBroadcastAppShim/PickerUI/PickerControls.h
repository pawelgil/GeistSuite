#pragma once

#import <UIKit/UIKit.h>

@interface GCFooterButton : UIControl
- (void)setTitle:(NSString *)title;
@end

@interface GCCircleGlassButton : UIControl
@property (nonatomic, strong, readonly) UIImageView *iconView;
@property (nonatomic, assign) BOOL isOn;
@property (nonatomic, strong) UIColor *onTint;
@property (nonatomic, strong) UIColor *offTint;
- (instancetype)initWithSize:(CGFloat)size;
@end
