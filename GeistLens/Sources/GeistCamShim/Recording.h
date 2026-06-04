// One GeistCamMovieRecording per active AVCaptureMovieFileOutput recording. Lazily
// creates the AVAssetWriter on first video frame and writes at source rate.

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "Source.h"

@interface GeistCamMovieRecording : NSObject
@property (nonatomic, weak) id delegate;
@property (nonatomic, strong) NSURL *outputURL;
@property (nonatomic, strong) AVAssetWriter *writer;
@property (nonatomic, strong) AVAssetWriterInput *videoInput;
@property (nonatomic, strong) AVAssetWriterInput *audioInput;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, assign) BOOL writerStarted;
@property (nonatomic, assign) CMTime startPTS;
@property (nonatomic, assign) CMFormatDescriptionRef audioFormatHint;
// Writer PTSes derive from per-track elapsed source-MP4 time so video and
// audio march at source rate, not host-time decode rate. Without these,
// video duration stretches and audio finishes ahead of video on playback.
@property (nonatomic, assign) double videoElapsedSec;
@property (nonatomic, assign) double audioElapsedSec;
@property (nonatomic, assign) CMTime videoLastSrcPTS;
@property (nonatomic, assign) CMTime audioLastSrcPTS;
@end

void appendToRecording(GeistCamMovieRecording *rec, GeistCamSource *src,
                       CMSampleBufferRef sb, CMTime originalSrcPTS);
