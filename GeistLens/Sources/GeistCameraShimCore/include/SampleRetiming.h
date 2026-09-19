#pragma once

#import <CoreMedia/CoreMedia.h>

CMSampleBufferRef _Nullable GeistCamCopyRetimedUniformSampleBuffer(
    CMSampleBufferRef _Nullable sampleBuffer,
    CMTime presentationTime) CF_RETURNS_RETAINED;
