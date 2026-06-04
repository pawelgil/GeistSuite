#pragma once

#import <Foundation/Foundation.h>

void GC_StartFeedThread(id broadcastHandler);
void GC_StopFeedThread(void);
void GC_SetFeedPaused(BOOL paused);
void GC_SetMicAudioReadiness(BOOL ready);
