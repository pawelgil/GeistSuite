// Per-slot record of the format AVF has currently selected on our minted
// devices. Updated by the setActiveFormat swizzle, sent to the lib via the
// ACTIVE_FORMAT wire message so producers can reformat to match.

#pragma once
#import <Foundation/Foundation.h>
#include "Wire.h"

void activeFormatRecord(NSString *deviceUID, int32_t width, int32_t height, uint32_t pixelFormat);
BOOL activeFormatGet(GeistCamSlot slot, int32_t *outWidth, int32_t *outHeight, uint32_t *outPixelFormat);
void activeFormatResyncForNewFeeder(void);

@class AVCaptureSession;
// Walks session.inputs, reads each device's activeFormat, records it.
// Catches AVF's silent format changes (e.g., addInput on a new device without
// a corresponding setActiveFormat call).
void activeFormatSnapshotSession(AVCaptureSession *session);
