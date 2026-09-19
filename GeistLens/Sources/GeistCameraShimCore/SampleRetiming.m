#import "SampleRetiming.h"

CMSampleBufferRef GeistCamCopyRetimedUniformSampleBuffer(
    CMSampleBufferRef sampleBuffer, CMTime presentationTime) {
    if (!sampleBuffer || !CMTIME_IS_NUMERIC(presentationTime)) return NULL;

    CMItemCount timingCount = 0;
    OSStatus status = CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, 0, NULL, &timingCount);
    if (status != noErr || timingCount != 1) return NULL;

    CMSampleTimingInfo timing;
    status = CMSampleBufferGetSampleTimingInfo(sampleBuffer, 0, &timing);
    if (status != noErr) return NULL;
    timing.presentationTimeStamp = presentationTime;
    timing.decodeTimeStamp = kCMTimeInvalid;

    CMSampleBufferRef result = NULL;
    status = CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, sampleBuffer, 1, &timing, &result);
    if (status != noErr) {
        if (result) CFRelease(result);
        return NULL;
    }
    return result;
}
