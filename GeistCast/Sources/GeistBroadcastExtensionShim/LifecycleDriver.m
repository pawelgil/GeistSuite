#import "LifecycleDriver.h"
#import "BackgroundKeepalive.h"
#import "FeedThread.h"
#import "FrameSocket.h"
#import "HandlerResolver.h"
#import "ControlSocket.h"
#import "ShimLog.h"

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <signal.h>
#include <stdatomic.h>
#include <unistd.h>

static id gBroadcastHandler = nil;
static IMP gOriginalFinishBroadcastIMP = NULL;
static volatile atomic_bool gFinishSwizzleInstalled = ATOMIC_VAR_INIT(false);

NSString *GC_BroadcastEventLine(NSDictionary *broadcast, NSString *type) {
    NSDictionary *envelope = @{
        @"type": type,
        @"simulatorUDID": broadcast[@"simulatorUDID"] ?: @"",
        @"hostAppBundleID": broadcast[@"hostAppBundleID"] ?: @"",
        @"extensionBundleID": broadcast[@"extensionBundleID"] ?: @"",
        @"startedAt": broadcast[@"startedAt"] ?: @"",
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:nil];
    NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [line stringByAppendingString:@"\n"];
}

void GC_StopBroadcast(void) {
    if (!gBroadcastHandler) return;
    GC_LOG("stopping broadcast");
    // Hard ceiling on teardown — real iOS SIGKILLs the extension if it
    // doesn't terminate cleanly within ~5s after broadcastFinished. 8s
    // gives the normal broadcastFinished + 5s grace path room to finish
    // and exit at ~5–6s; only fires when something deadlocked.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        GC_ERR("teardown watchdog fired; forcing exit");
        _exit(1);
    });
    GC_StopFeedThread();
    id handler = gBroadcastHandler;
    gBroadcastHandler = nil;
    SEL finSel = sel_registerName("broadcastFinished");
    if ([handler respondsToSelector:finSel]) {
        IMP imp = [handler methodForSelector:finSel];
        typedef void (*Fn)(id, SEL);
        ((Fn)imp)(handler, finSel);
    }
    // Real ReplayKit gives the extension ~5s of grace after
    // broadcastFinished returns before suspending it. Mirror that here so
    // async AVAssetWriter flushes have time to complete before the
    // lifecycle driver tears down the process.
    usleep(5 * 1000 * 1000);
    GC_DropFrameClient();
    GC_LOG("broadcast finished");
}

static dispatch_source_t gSIGTERMSource = NULL;

static void GC_InstallSIGTERMHandler(void) {
    if (gSIGTERMSource) return;
    // Signal-handler context isn't async-signal-safe for malloc/libobjc/
    // libdispatch — route via dispatch source so the work runs on a queue.
    signal(SIGTERM, SIG_IGN);
    gSIGTERMSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)
    );
    dispatch_source_set_event_handler(gSIGTERMSource, ^{
        GC_LOG("SIGTERM received");
        GC_StopBroadcast();
        _exit(0);
    });
    dispatch_resume(gSIGTERMSource);
}

static NSString *GC_ExtensionTerminatedLine(NSError *error) {
    NSDictionary *envelope = @{
        @"type": @"extension_terminated",
        @"errorDomain": error.domain ?: @"",
        @"errorCode": @(error.code),
        @"errorMessage": error.localizedDescription ?: @"",
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:nil];
    NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [line stringByAppendingString:@"\n"];
}

static void GC_FinishBroadcastSwizzled(id self_, SEL _cmd, NSError *error) {
    (void)_cmd;
    GC_LOG("intercepted finishBroadcastWithError: domain=%{public}@ code=%ld",
           error.domain, (long)error.code);
    GC_WriteControlLine(GC_ExtensionTerminatedLine(error));
    GC_StopBroadcast();
    _exit(0);
}

void GC_InstallFinishBroadcastSwizzle(void) {
    bool expected = false;
    if (!atomic_compare_exchange_strong(&gFinishSwizzleInstalled, &expected, true)) {
        return;
    }
    Class base = NSClassFromString(@"RPBroadcastSampleHandler");
    if (!base) {
        GC_ERR("finishBroadcastWithError swizzle: RPBroadcastSampleHandler not found");
        return;
    }
    SEL sel = sel_registerName("finishBroadcastWithError:");
    Method method = class_getInstanceMethod(base, sel);
    if (!method) {
        GC_ERR("finishBroadcastWithError swizzle: method not found on base class");
        return;
    }
    gOriginalFinishBroadcastIMP = method_setImplementation(
        method, (IMP)GC_FinishBroadcastSwizzled
    );
    GC_LOG("finishBroadcastWithError: swizzle installed");
}

void GC_StartLifecycleDriver(void) {
    GC_KeepAliveInBackground();

    // Drive the protocol on a background queue so the NSExtensionMain
    // interpose can keep the main runloop alive.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        const char *extDylib = getenv("GEISTCAST_EXTENSION_DEBUG_DYLIB");
        if (extDylib && extDylib[0]) {
            void *h = dlopen(extDylib, RTLD_NOW | RTLD_GLOBAL);
            if (!h) {
                GC_ERR("dlopen(%{public}s) failed: %{public}s", extDylib, dlerror());
            } else {
                GC_LOG("dlopen'd %{public}s", extDylib);
            }
        }

        if (!GC_OpenControlConnection()) {
            GC_ERR("no control connection — exiting");
            _exit(1);
        }

        NSString *extBundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        NSDictionary *hello = @{
            @"type": @"hello",
            @"role": @"extension",
            @"extensionBundleID": extBundleID,
        };
        NSData *helloData = [NSJSONSerialization dataWithJSONObject:hello options:0 error:nil];
        NSString *helloLine = [[NSString alloc] initWithData:helloData encoding:NSUTF8StringEncoding];
        GC_WriteControlLine([helloLine stringByAppendingString:@"\n"]);
        GC_LOG("sent helloExtension extBundleID=%{public}@", extBundleID);

        // Resolve the principal class while still waiting on `begin` so
        // class-loading and the network roundtrip overlap.
        Class principal = nil;
        for (int attempt = 0; attempt < 100 && !principal; ++attempt) {
            principal = GC_FindBroadcastHandlerClass();
            if (!principal) usleep(50 * 1000);
        }
        if (!principal) {
            GC_ERR("no RPBroadcastSampleHandler subclass after retries");
            _exit(1);
        }
        GC_LOG("principal class %{public}s", class_getName(principal));
        GC_InstallFinishBroadcastSwizzle();

        NSMutableData *carryOver = [NSMutableData data];
        NSDictionary *beginEnvelope = nil;
        while (true) {
            NSDictionary *msg = GC_ReadControlMessage(carryOver);
            if (!msg) {
                GC_ERR("control closed while waiting for begin");
                _exit(1);
            }
            NSString *type = msg[@"type"];
            if ([type isEqual:@"begin"]) { beginEnvelope = msg; break; }
            GC_LOG("ignoring unexpected %{public}@ message before begin", type);
        }
        GC_LOG("received begin");

        id handler = [[principal alloc] init];
        if (!handler) {
            GC_ERR("principal alloc/init returned nil");
            _exit(1);
        }
        GC_InstallSIGTERMHandler();

        SEL startSel = sel_registerName("broadcastStartedWithSetupInfo:");
        if ([handler respondsToSelector:startSel]) {
            IMP imp = [handler methodForSelector:startSel];
            typedef void (*Fn)(id, SEL, id);
            ((Fn)imp)(handler, startSel, nil);
        }
        gBroadcastHandler = handler;
        GC_StartFeedThread(handler);

        GC_WriteControlLine(GC_BroadcastEventLine(beginEnvelope, @"started"));
        GC_LOG("emitted started ack");

        while (true) {
            NSDictionary *msg = GC_ReadControlMessage(carryOver);
            if (!msg) {
                GC_LOG("control closed — treating as finish");
                break;
            }
            NSString *type = msg[@"type"];
            if ([type isEqual:@"finish"]) {
                GC_LOG("received finish");
                break;
            }
            if ([type isEqual:@"pause"]) {
                GC_LOG("received pause");
                GC_SetFeedPaused(YES);
                SEL pauseSel = sel_registerName("broadcastPaused");
                if ([handler respondsToSelector:pauseSel]) {
                    IMP imp = [handler methodForSelector:pauseSel];
                    typedef void (*Fn)(id, SEL);
                    ((Fn)imp)(handler, pauseSel);
                }
                continue;
            }
            if ([type isEqual:@"resume"]) {
                GC_LOG("received resume");
                SEL resumeSel = sel_registerName("broadcastResumed");
                if ([handler respondsToSelector:resumeSel]) {
                    IMP imp = [handler methodForSelector:resumeSel];
                    typedef void (*Fn)(id, SEL);
                    ((Fn)imp)(handler, resumeSel);
                }
                GC_SetFeedPaused(NO);
                continue;
            }
            if ([type isEqual:@"set_mic_audio_readiness"]) {
                BOOL ready = [msg[@"ready"] boolValue];
                GC_LOG("received set_mic_audio_readiness ready=%d", ready);
                GC_SetMicAudioReadiness(ready);
                continue;
            }
            GC_LOG("ignoring unexpected %{public}@ message after start", type);
        }

        GC_StopBroadcast();
        GC_WriteControlLine(GC_BroadcastEventLine(beginEnvelope, @"ended"));
        GC_LOG("emitted ended ack; exiting");
        _exit(0);
    });
}
