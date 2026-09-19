#pragma once

#import <Foundation/Foundation.h>

typedef NSArray * _Nullable (^GeistCamSourceLoader)(BOOL * _Nonnull shouldCache);

@interface GeistCamSerializedSourceProvider : NSObject

- (NSArray * _Nullable)copySourcesWithLoader:(GeistCamSourceLoader _Nonnull)loader
    NS_RETURNS_RETAINED;

@end
