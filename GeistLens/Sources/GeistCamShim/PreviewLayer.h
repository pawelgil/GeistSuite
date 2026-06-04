// AVCaptureVideoPreviewLayer's internal CALayer is dead in the simulator (no
// Fig pipeline) — we inject our own AVSampleBufferDisplayLayer sublayer and
// feed it from the pacing thread.

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "Source.h"

void installPreviewSwizzles(void);

void deliverFrameToPreviewLayers(CMSampleBufferRef sb, GeistCamSource *src);
void invalidatePreviewBindings(void);
void blankPreviewLayersForSession(AVCaptureSession *session);
