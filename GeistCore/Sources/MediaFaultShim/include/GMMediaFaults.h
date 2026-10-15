#import <AVFoundation/AVFoundation.h>
#import "GMFaultController.h"

NS_ASSUME_NONNULL_BEGIN
@interface GMMediaFaults : NSObject
+ (nullable GMFaultController *)controller;
+ (void)installWithWriterErrorCode:(NSInteger)code underlyingCode:(NSInteger)underlyingCode exportHooks:(BOOL)exportHooks logger:(void (^)(NSString *))logger NS_SWIFT_NAME(install(writerErrorCode:underlyingCode:exportHooks:logger:));
+ (BOOL)rejectAppendForWriter:(nullable AVAssetWriter *)writer mediaType:(NSString *)mediaType NS_SWIFT_NAME(rejectAppend(writer:mediaType:));
@end
NS_ASSUME_NONNULL_END
