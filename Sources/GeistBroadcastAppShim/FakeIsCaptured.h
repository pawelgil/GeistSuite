#pragma once

#import <Foundation/Foundation.h>

BOOL GC_FakeCaptured(void);
void GC_SetFakeCaptured(BOOL on);
NSDate *GC_GetRecordingStartDate(void);
void GC_SetRecordingStartDate(NSDate *date);
void GC_PostScreenCapturedChange(void);
void GC_InstallIsCapturedSwizzle(void);

BOOL GC_MicEnabled(void);
void GC_SetMicEnabled(BOOL enabled);

// macOS-side TCC mic permission, as last reported by the daemon's state
// envelope. Defaults to YES so we don't surface a warning before the
// handshake completes.
BOOL GC_MacOSMicAuthorized(void);
void GC_SetMacOSMicAuthorized(BOOL authorized);
