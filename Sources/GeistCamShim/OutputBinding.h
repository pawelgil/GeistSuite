#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "Source.h"

typedef struct OutputBinding {
    id output;                  // weak — session retains
    GeistCamSource *source;
    AVCaptureSession *session;  // weak — caller retains
} OutputBinding;

#define GEISTCAM_MAX_OUTPUTS 16

void rebuildOutputBindingsForSession(AVCaptureSession *session);

// Caller-owned snapshot — buffer must hold GEISTCAM_MAX_OUTPUTS. Returns count.
int snapshotOutputBindings(OutputBinding *outBuf);

BOOL isSourceActive(GeistCamSource *src);

// Centralized so the swizzles writing state and pacing thread reading state
// share the same address.
extern const void *kGeistCamRecordingKey;        // GeistCamMovieRecording on AVCaptureMovieFileOutput
extern const void *kGeistCamSampleDelegateKey;   // delegate on AVCapture(Video|Audio)DataOutput
extern const void *kGeistCamSampleQueueKey;      // queue on AVCapture(Video|Audio)DataOutput
