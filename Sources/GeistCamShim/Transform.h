// On a real device the ISP applies rotation/mirror/zoom before the buffer
// reaches the app. Our synthesized frames need this pipeline applied
// explicitly so apps that set rotation/mirror via AVCaptureConnection see
// the output they expect.

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

typedef struct TransformParams {
    CGFloat rotationDegrees;   // 0/90/180/270 clockwise
    BOOL mirrored;
    CGFloat zoomFactor;        // ≥ 1.0
    int32_t targetWidth;       // activeFormat width (unswapped); 0 → derive from input
    int32_t targetHeight;      // activeFormat height (unswapped); 0 → derive from input
} TransformParams;

TransformParams transformParamsForConnection(AVCaptureConnection *conn);

// Returns a transformed sample buffer (caller CFReleases), or NULL when
// params are identity — caller should use the original buffer in that case.
CMSampleBufferRef applyTransformToSampleBuffer(CMSampleBufferRef sb, TransformParams params);
