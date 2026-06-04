#import "WriterTracker.h"
#import "RecordingState.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

static const void *kGeistCamWriterTrackerKey = &kGeistCamWriterTrackerKey;

@implementation GeistCamWriterTracker {
    __weak AVAssetWriter *_writer;
    BOOL _observing;
}

- (instancetype)initWithWriter:(AVAssetWriter *)writer {
    if ((self = [super init])) {
        _writer = writer;
        _observing = YES;
        [writer addObserver:self forKeyPath:@"status" options:0 context:NULL];
    }
    return self;
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    AVAssetWriter *writer = (AVAssetWriter *)object;
    AVAssetWriterStatus status = writer.status;
    if (status == AVAssetWriterStatusCompleted ||
        status == AVAssetWriterStatusFailed ||
        status == AVAssetWriterStatusCancelled) {
        recordingAssetWriterTerminated(writer);
        [self stopObserving];
    }
}

- (void)stopObserving {
    if (!_observing) return;
    AVAssetWriter *writer = _writer;
    if (writer) {
        @try {
            [writer removeObserver:self forKeyPath:@"status"];
        } @catch (NSException *e) {
            // Defensive: KVO throws if observer wasn't registered.
        }
    }
    _observing = NO;
}

- (void)dealloc {
    [self stopObserving];
}

@end

void installWriterTracker(AVAssetWriter *writer) {
    if (!writer) return;
    if (objc_getAssociatedObject(writer, kGeistCamWriterTrackerKey)) return;
    GeistCamWriterTracker *tracker = [[GeistCamWriterTracker alloc] initWithWriter:writer];
    objc_setAssociatedObject(writer, kGeistCamWriterTrackerKey, tracker,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
