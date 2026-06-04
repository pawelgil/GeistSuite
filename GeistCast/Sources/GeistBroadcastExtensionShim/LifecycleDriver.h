#pragma once

#import <Foundation/Foundation.h>

void GC_StartLifecycleDriver(void);
void GC_StopBroadcast(void);
NSString *GC_BroadcastEventLine(NSDictionary *broadcast, NSString *type);
void GC_InstallFinishBroadcastSwizzle(void);
