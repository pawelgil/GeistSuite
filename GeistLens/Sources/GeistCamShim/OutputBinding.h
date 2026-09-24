#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "Source.h"

@interface GCOutputBinding : NSObject
@property(nonatomic, weak) id output;
@property(nonatomic, assign) GeistCamSource *source;
@property(nonatomic, weak) AVCaptureSession *session;
@property(nonatomic, copy) NSString *sessionID;
@end

#define GEISTCAM_MAX_OUTPUTS 16

void rebuildOutputBindingsForSession(AVCaptureSession *session);
void removeOutputBindingsForSessionID(NSString *sessionID);

NSArray<GCOutputBinding *> *snapshotOutputBindings(void);

BOOL isSourceActive(GeistCamSource *src);

// Centralized so the swizzles writing state and pacing thread reading state
// share the same address.
extern const void *kGeistCamRecordingKey;        // GeistCamMovieRecording on AVCaptureMovieFileOutput
extern const void *kGeistCamSampleDelegateKey;   // delegate on AVCapture(Video|Audio)DataOutput
extern const void *kGeistCamSampleQueueKey;      // queue on AVCapture(Video|Audio)DataOutput
