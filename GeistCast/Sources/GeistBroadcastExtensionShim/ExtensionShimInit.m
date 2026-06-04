#import "LifecycleDriver.h"
#import "ShimLog.h"

#import <Foundation/Foundation.h>
#include <unistd.h>

os_log_t gc_log(void) {
    static os_log_t l;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ l = os_log_create("com.geistcast.shim.extension", "Shim"); });
    return l;
}

__attribute__((constructor))
static void GeistBroadcastExtensionShim_Init(void) {
    @autoreleasepool {
        GC_LOG("+ctor pid=%d bundle=%{public}@",
               getpid(), [[NSBundle mainBundle] bundleIdentifier] ?: @"?");
        GC_StartLifecycleDriver();
    }
}
