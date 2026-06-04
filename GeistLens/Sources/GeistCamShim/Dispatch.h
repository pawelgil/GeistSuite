// One CMSampleBuffer → every AVF output bound to the source. Per-output
// transforms applied for video.

#pragma once
#import <CoreMedia/CoreMedia.h>
#import "Source.h"

void deliverToBoundOutputs(GeistCamSource *src, CMSampleBufferRef sb, CMTime originalSrcPTS);
