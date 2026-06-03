#pragma once
#include <stdint.h>
#include <stdbool.h>

typedef struct {
    int x;
    int y;
    int w;
    int h;
} GeistCamRect;

typedef struct {
    int outputW;
    int outputH;
    GeistCamRect sourceCrop;   // image coords (top-left origin); symmetric so CI's Y-up doesn't matter
    double scale;
    bool isIdentity;
} GeistCamTransformPlan;

// Center-crop + aspect-fill plan emulating iPhone camera HW. Only 90 and 270
// produce dim-swapped (portrait) output; 0 and 180 keep landscape dims and
// pixel rotation is the caller's job. activeFormatW/H == 0 falls back to
// input dims (the shim hasn't seen ACTIVE_FORMAT yet for this slot).
//
// Pure: no AVF, no CoreImage, no UIKit. Caller renders via CIImage or vImage.
GeistCamTransformPlan geistcam_computeTransformPlan(
    int inputW, int inputH,
    int activeFormatW, int activeFormatH,
    int rotationDegrees);

// Combines a source's feature bitset with the iOS app's connection.videoMirrored
// to decide whether the shim should apply a horizontal flip. Only live-capture
// sources (mac cam) honor the front-cam mirror convention; mp4/image/pattern
// sources are recorded content and stay un-flipped regardless.
bool geistcam_shouldMirror(uint32_t features, bool connectionMirrored);
