#pragma once

#ifdef __OBJC__
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GCAppGroupContainerAliases : NSObject
+ (void)install;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithDirectoryURL:(NSURL *)directoryURL;
- (nullable NSURL *)containerURLForURL:(nullable NSURL *)containerURL NS_SWIFT_NAME(containerURL(for:));
@end

NS_ASSUME_NONNULL_END
#endif
