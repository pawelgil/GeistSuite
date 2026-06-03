#pragma once

#import <Foundation/Foundation.h>

void GC_HandshakeHost(NSMutableData *carryOver);
void GC_StartHostControlReader(NSMutableData *carryOver);
void GC_SendUserPressedStart(BOOL micEnabled);
void GC_SendUserCancelledStart(void);
void GC_SendUserPressedStop(void);
void GC_SendUserToggledMic(BOOL enabled);
