#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

typedef NS_ENUM(NSInteger, GeistCamTransformDelivery) {
    GeistCamTransformDeliveryPresentation,
    GeistCamTransformDeliveryDataOutput,
};

typedef struct TransformParams {
    GeistCamTransformDelivery delivery;
    CGFloat rotationDegrees;   // 0/90/180/270 clockwise
    BOOL mirrored;
    CGFloat zoomFactor;        // ≥ 1.0
    int32_t targetWidth;       // activeFormat width (unswapped); 0 → derive from input
    int32_t targetHeight;      // activeFormat height (unswapped); 0 → derive from input
} TransformParams;

TransformParams transformParamsForConnection(AVCaptureConnection *conn, GeistCamTransformDelivery delivery);

// Returns a transformed sample buffer (caller CFReleases), or NULL when
// params are identity — caller should use the original buffer in that case.
CMSampleBufferRef applyTransformToSampleBuffer(CMSampleBufferRef sb, TransformParams params);
