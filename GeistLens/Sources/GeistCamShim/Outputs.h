#import <AVFoundation/AVFoundation.h>

void installMovieFileSwizzles(void);
void interruptMovieFileOutputsForSession(AVCaptureSession *session);
void installDataOutputSwizzles(void);
void installPhotoSwizzles(void);
void installCapabilitySwizzles(void);
