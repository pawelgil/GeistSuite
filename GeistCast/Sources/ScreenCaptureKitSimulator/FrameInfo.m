#import "FrameSocket.h"
#import "GeistScreenCaptureWire.h"

#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <objc/runtime.h>

NSErrorDomain const SCStreamErrorDomain = @"com.apple.ScreenCaptureKit.SCStreamErrorDomain";
SCStreamFrameInfo const SCStreamFrameInfoStatus = @"SCStreamFrameInfoStatus";
SCStreamFrameInfo const SCStreamFrameInfoDisplayTime = @"SCStreamFrameInfoDisplayTime";
SCStreamFrameInfo const SCStreamFrameInfoScaleFactor = @"SCStreamFrameInfoScaleFactor";
SCStreamFrameInfo const SCStreamFrameInfoContentScale = @"SCStreamFrameInfoContentScale";
SCStreamFrameInfo const SCStreamFrameInfoContentRect = @"SCStreamFrameInfoContentRect";
SCStreamFrameInfo const SCStreamFrameInfoScreenRect = @"SCStreamFrameInfoScreenRect";
SCStreamFrameInfo const SCStreamFrameInfoVideoOrientation = @"SCStreamFrameInfoVideoOrientation";

