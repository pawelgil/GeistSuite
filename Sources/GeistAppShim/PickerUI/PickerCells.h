#pragma once

#import <UIKit/UIKit.h>

@interface GCRecordDotView : UIView
@property (nonatomic, assign) BOOL isRecording;
@property (nonatomic, copy) NSString *countdownText;
@end

@interface GCBroadcastAppCell : UITableViewCell
- (void)configureWithTitle:(NSString *)title
                 iconImage:(UIImage *)iconImage
                isSelected:(BOOL)isSelected
               isRecording:(BOOL)isRecording
              durationText:(NSString *)durationText;
@end
