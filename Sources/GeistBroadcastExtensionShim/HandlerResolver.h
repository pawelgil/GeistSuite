#pragma once

#import <Foundation/Foundation.h>

BOOL GC_IsSubclassOf(Class cls, Class base);
Class GC_FindBroadcastHandlerClass(void);
