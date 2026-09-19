#import "RecordingTimeline.h"

#import <math.h>

static const double GeistCamDefaultAudioFrameDuration = 1024.0 / 48000.0;
static const double GeistCamDefaultVideoFrameDuration = 1.0 / 30.0;

static double usableSampleDuration(CMTime sampleDuration) {
    double duration = CMTimeGetSeconds(sampleDuration);
    return isfinite(duration) && duration > 0 && duration <= 1.0 ? duration : 0;
}

double GeistCamRecordingAdvanceElapsed(
    double elapsed,
    CMTime lastSourceTime,
    CMTime currentSourceTime,
    double fallbackDuration) {
    if (!CMTIME_IS_VALID(lastSourceTime)) return elapsed;

    double usableFallback = isfinite(fallbackDuration) && fallbackDuration > 0
        ? fallbackDuration
        : GeistCamDefaultVideoFrameDuration;
    double delta = CMTimeGetSeconds(CMTimeSubtract(currentSourceTime, lastSourceTime));
    if (!isfinite(delta) || delta <= 0 || delta > 1.0) delta = usableFallback;
    return elapsed + delta;
}

double GeistCamRecordingAudioFrameDuration(CMTime sampleDuration) {
    double duration = usableSampleDuration(sampleDuration);
    return duration > 0 ? duration : GeistCamDefaultAudioFrameDuration;
}

double GeistCamRecordingVideoFrameDuration(CMTime sampleDuration, double frameRate) {
    double duration = usableSampleDuration(sampleDuration);
    if (duration > 0) return duration;
    if (!isfinite(frameRate) || frameRate <= 0) return GeistCamDefaultVideoFrameDuration;
    double frameRateDuration = 1.0 / frameRate;
    return isfinite(frameRateDuration) && frameRateDuration > 0
        ? frameRateDuration
        : GeistCamDefaultVideoFrameDuration;
}
