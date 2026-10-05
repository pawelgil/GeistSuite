#import "ImageTransform.h"

static CIImage *normalizedImage(CIImage *image) {
    return [image imageByApplyingTransform:CGAffineTransformMakeTranslation(
        -image.extent.origin.x, -image.extent.origin.y)];
}

static CIImage *zoomedImage(CIImage *image, double zoomFactor) {
    if (zoomFactor <= 1.0001) return image;
    CGRect extent = image.extent;
    CGFloat width = extent.size.width / zoomFactor;
    CGFloat height = extent.size.height / zoomFactor;
    CGRect crop = CGRectMake(extent.origin.x + (extent.size.width - width) / 2,
                             extent.origin.y + (extent.size.height - height) / 2, width, height);
    image = normalizedImage([image imageByCroppingToRect:crop]);
    return [image imageByApplyingTransform:CGAffineTransformMakeScale(zoomFactor, zoomFactor)];
}

CIImage *geistcam_imageByApplyingTransformPlan(
    CIImage *image, GeistCamTransformPlan plan, bool mirrored, double zoomFactor)
{
    if (mirrored) {
        image = normalizedImage([image imageByApplyingTransform:CGAffineTransformMakeScale(-1, 1)]);
    }
    image = zoomedImage(image, zoomFactor);
    switch (plan.pixelRotationDegrees) {
        case 90: image = [image imageByApplyingOrientation:kCGImagePropertyOrientationRight]; break;
        case 180: image = [image imageByApplyingOrientation:kCGImagePropertyOrientationDown]; break;
        case 270: image = [image imageByApplyingOrientation:kCGImagePropertyOrientationLeft]; break;
        default: break;
    }
    image = normalizedImage(image);
    CGRect crop = CGRectMake(plan.sourceCrop.x, plan.sourceCrop.y, plan.sourceCrop.w, plan.sourceCrop.h);
    image = normalizedImage([image imageByCroppingToRect:crop]);
    return [image imageByApplyingTransform:CGAffineTransformMakeScale(plan.scale, plan.scale)];
}
