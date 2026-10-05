#pragma once
#import <CoreImage/CoreImage.h>
#include "TransformPlan.h"

CIImage * _Nonnull geistcam_imageByApplyingTransformPlan(
    CIImage * _Nonnull image, GeistCamTransformPlan plan, bool mirrored, double zoomFactor);
