#pragma once

#import <CoreMedia/CoreMedia.h>

double GeistCamRecordingAdvanceElapsed(
    double elapsed,
    CMTime lastSourceTime,
    CMTime currentSourceTime,
    double fallbackDuration);

double GeistCamRecordingAudioFrameDuration(CMTime sampleDuration);

double GeistCamRecordingVideoFrameDuration(CMTime sampleDuration, double frameRate);
