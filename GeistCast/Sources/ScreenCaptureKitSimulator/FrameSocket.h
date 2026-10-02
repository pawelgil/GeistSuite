#pragma once

#import <CoreMedia/CoreMedia.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

typedef struct {
    CMSampleBufferRef sampleBuffer;
    SCStreamOutputType type;
} GSCKDeliveredSample;

int GSCKConnect(uint32_t outputs, int32_t *status);
bool GSCKIsAvailable(void);
void GSCKClose(int fd);
void GSCKShutdown(int fd);
GSCKDeliveredSample GSCKReadNextSample(int fd);
