#pragma once
#import <UIKit/UIKit.h>

@interface GCDismissBackdropView : UIView
@property (nonatomic) BOOL dismissalEnabled;
@property (nonatomic, copy, nullable) void (^dismissalHandler)(void);
@end
