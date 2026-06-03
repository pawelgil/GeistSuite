#import <Foundation/Foundation.h>
@class AVAssetWriter;

@interface GeistCamWriterTracker : NSObject
- (instancetype)initWithWriter:(AVAssetWriter *)writer;
@end

void installWriterTracker(AVAssetWriter *writer);
