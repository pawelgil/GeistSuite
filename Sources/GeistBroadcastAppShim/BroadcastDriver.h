#pragma once

#import <Foundation/Foundation.h>

@interface GeistCastBroadcastDriver : NSObject
+ (instancetype)shared;
- (void)tap:(id)sender;
@end
