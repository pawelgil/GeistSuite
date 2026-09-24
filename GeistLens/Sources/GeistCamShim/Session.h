#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

BOOL isSessionRunning(AVCaptureSession *sess);
BOOL isSessionDelivering(AVCaptureSession *sess);
BOOL isCameraSessionDeallocating(AVCaptureSession *session);
uint64_t sessionDeliveryGeneration(AVCaptureSession *session);
BOOL beginSessionDelivery(AVCaptureSession *session, uint64_t generation);
void endSessionDelivery(AVCaptureSession *session);
BOOL isAppBackgrounded(void);
NSArray<AVCaptureSession *> *snapshotRunningSessions(void);
NSString *cameraSessionIdentifier(AVCaptureSession *session);

NSDictionary *cameraHandleControlRequest(NSDictionary *request);

void installSessionSwizzles(void);
void installLifecycleObservers(void);
