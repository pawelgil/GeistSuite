#import "HostControl.h"
#import "PickerSwizzle.h"
#import "FakeIsCaptured.h"
#import "ControlSocket.h"
#import "ShimLog.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <unistd.h>

os_log_t gc_log(void) {
    static os_log_t l;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ l = os_log_create("com.geistcast.shim.app", "Shim"); });
    return l;
}

__attribute__((constructor))
static void GeistBroadcastAppShim_Init(void) {
    @autoreleasepool {
        GC_LOG("+ctor pid=%d bundle=%{public}@",
               getpid(), [[NSBundle mainBundle] bundleIdentifier] ?: @"?");

        // Seed picker state from the daemon BEFORE installing swizzles, so
        // a tap that arrives mid-broadcast sees the correct initial state.
        // The handshake blocks briefly on the state reply, so run it off
        // the main thread.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            if (GC_OpenControlConnection()) {
                NSMutableData *carryOver = [NSMutableData data];
                GC_HandshakeHost(carryOver);
                GC_StartHostControlReader(carryOver);
            }
        });

        // ReplayKit may not yet be loaded into the process at ctor time, so
        // poll until the picker class appears before swizzling.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            BOOL installed = NO;
            for (int attempt = 0; attempt < 200; ++attempt) {
                if (NSClassFromString(@"RPSystemBroadcastPickerView")) {
                    // UIKit access requires the main queue.
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        GC_InstallPickerSwizzle();
                        GC_InstallPickerInitSwizzle();
                        GC_InstallSendActionSwizzle();
                        GC_InstallIsCapturedSwizzle();
                        GC_ScanAllWindowsForPickers();
                    });
                    installed = YES;
                    break;
                }
                usleep(50 * 1000);
            }
            if (!installed) {
                GC_LOG("picker class never appeared; no swizzle installed");
                return;
            }
            // Re-scan a few times to catch picker views added late.
            for (int i = 0; i < 5; ++i) {
                usleep(500 * 1000);
                dispatch_sync(dispatch_get_main_queue(), ^{
                    GC_ScanAllWindowsForPickers();
                });
            }
        });
    }
}
