#pragma once

#import <CoreMedia/CoreMedia.h>

// Raw values must mirror ReplayKit's RPSampleBufferType exactly. FeedThread
// casts this enum to NSInteger and passes it as the `withType:` argument of
// processSampleBuffer:withType:; if these drift from Apple's values, mic
// samples arrive at handlers tagged as audioApp and get silently dropped.
typedef NS_ENUM(NSInteger, GCFeedSampleBufferType) {
    GCFeedSampleBufferTypeVideo = 1,
    GCFeedSampleBufferTypeAudioApp = 2,
    GCFeedSampleBufferTypeAudioMic = 3,
};

typedef struct {
    CMSampleBufferRef sampleBuffer;
    GCFeedSampleBufferType type;
} GCDeliveredSample;

int GC_OpenFrameSocket(void);
void GC_DropFrameClient(void);

GCDeliveredSample GC_ReadNextSample(int fd, BOOL micUnreadyOverride);
