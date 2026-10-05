#include "TransformPlan.h"
#include "MediaSourceFeatures.h"

GeistCamTransformPlan geistcam_computeTransformPlan(
    int inputW, int inputH,
    int activeFormatW, int activeFormatH,
    int rotationDegrees)
{
    GeistCamTransformPlan plan;
    plan.outputW = 0;
    plan.outputH = 0;
    plan.sourceCrop = (GeistCamRect){0, 0, 0, 0};
    plan.scale = 1.0;
    plan.pixelRotationDegrees = 0;
    plan.isIdentity = true;

    if (inputW <= 0 || inputH <= 0) {
        return plan;
    }

    int baseW = activeFormatW > 0 ? activeFormatW : inputW;
    int baseH = activeFormatH > 0 ? activeFormatH : inputH;

    bool outIsPortrait = (rotationDegrees == 90 || rotationDegrees == 270);
    plan.outputW = outIsPortrait ? baseH : baseW;
    plan.outputH = outIsPortrait ? baseW : baseH;

    if (inputW == plan.outputW && inputH == plan.outputH) {
        plan.sourceCrop = (GeistCamRect){0, 0, inputW, inputH};
        plan.scale = 1.0;
        plan.isIdentity = true;
        return plan;
    }

    // Aspect-fill: source center-cropped to the target aspect ratio, then
    // scaled uniformly so the crop fills the output dims exactly.
    double inputAR = (double)inputW / (double)inputH;
    double outputAR = (double)plan.outputW / (double)plan.outputH;

    int cropW;
    int cropH;
    if (inputAR > outputAR) {
        cropH = inputH;
        cropW = (int)((double)inputH * outputAR + 0.5);
        if (cropW > inputW) cropW = inputW;
    } else if (inputAR < outputAR) {
        cropW = inputW;
        cropH = (int)((double)inputW / outputAR + 0.5);
        if (cropH > inputH) cropH = inputH;
    } else {
        cropW = inputW;
        cropH = inputH;
    }

    plan.sourceCrop.w = cropW;
    plan.sourceCrop.h = cropH;
    plan.sourceCrop.x = (inputW - cropW) / 2;
    plan.sourceCrop.y = (inputH - cropH) / 2;
    plan.scale = (double)plan.outputW / (double)cropW;
    plan.isIdentity = false;
    return plan;
}

int geistcam_portraitCaptureRotationDegrees(void)
{
    return 90;
}

GeistCamTransformPlan geistcam_computePortraitDataOutputPlan(
    int inputW, int inputH, int activeFormatW, int activeFormatH,
    int connectionRotationDegrees)
{
    // Upright portrait is +90 degrees from sensor space: https://developer.apple.com/videos/play/wwdc2023/10106/
    int rotation = (connectionRotationDegrees + 270) % 360;
    bool swapsDimensions = rotation == 90 || rotation == 270;
    int rotatedW = swapsDimensions ? inputH : inputW;
    int rotatedH = swapsDimensions ? inputW : inputH;
    int sensorW = activeFormatW > 0 ? activeFormatW : inputH;
    int sensorH = activeFormatH > 0 ? activeFormatH : inputW;
    GeistCamTransformPlan plan = geistcam_computeTransformPlan(
        rotatedW, rotatedH, sensorW, sensorH, connectionRotationDegrees);
    plan.pixelRotationDegrees = rotation;
    plan.isIdentity = plan.isIdentity && rotation == 0;
    return plan;
}

bool geistcam_shouldMirror(uint32_t features, bool connectionMirrored)
{
    if ((features & GEISTCAM_FEATURE_ALLOWS_FRONT_MIRROR) == 0) return false;
    return connectionMirrored;
}
