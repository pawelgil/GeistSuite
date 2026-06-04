#import <Foundation/Foundation.h>

void installRotationCoordinatorSwizzles(void);

// Current capture rotation in degrees (0/90/180/270) derived from the active
// UIWindowScene's interfaceOrientation. The shim uses this to emulate the
// iPhone camera HW, which rotates the buffer to the device's current
// orientation before delivering it to AVCaptureOutputs.
double geistcam_currentCaptureRotationDegrees(void);
