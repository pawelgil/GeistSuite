#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

BOOL isSessionRunning(AVCaptureSession *sess);
BOOL isAppBackgrounded(void);
NSArray<AVCaptureSession *> *snapshotRunningSessions(void);

void installSessionSwizzles(void);
void installLifecycleObservers(void);
