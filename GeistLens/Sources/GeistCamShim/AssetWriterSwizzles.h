#import <Foundation/Foundation.h>
@class AVAssetWriter;
@class AVAssetWriterInput;

void installAssetWriterSwizzles(void);

AVAssetWriter *writerForInput(AVAssetWriterInput *input);
