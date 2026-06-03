#import "BackgroundKeepalive.h"
#import "ShimLog.h"

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Claim an active audio session (no sound played) so iOS treats us as
// "playing audio" and won't suspend the process when the host app moves
// to the background. Requires UIBackgroundModes=audio in Info.plist.
void GC_KeepAliveInBackground(void) {
    Class sessionCls = NSClassFromString(@"AVAudioSession");
    if (!sessionCls) {
        GC_LOG("AVAudioSession not available — skipping keepalive");
        return;
    }
    SEL sharedSel = sel_registerName("sharedInstance");
    typedef id (*SharedFn)(Class, SEL);
    id sess = ((SharedFn)objc_msgSend)(sessionCls, sharedSel);
    if (!sess) return;

    SEL setCategorySel = sel_registerName("setCategory:mode:options:error:");
    typedef BOOL (*SetCatFn)(id, SEL, NSString *, NSString *, NSUInteger, NSError **);
    NSError *err = nil;
    BOOL ok = ((SetCatFn)objc_msgSend)(sess, setCategorySel,
                                       @"AVAudioSessionCategoryPlayback",
                                       @"AVAudioSessionModeMoviePlayback",
                                       0, &err);
    if (!ok) {
        GC_ERR("setCategory failed: %{public}@", err.localizedDescription ?: @"?");
    }
    SEL setActiveSel = sel_registerName("setActive:error:");
    typedef BOOL (*SetActFn)(id, SEL, BOOL, NSError **);
    err = nil;
    ok = ((SetActFn)objc_msgSend)(sess, setActiveSel, YES, &err);
    if (!ok) {
        GC_ERR("setActive failed: %{public}@", err.localizedDescription ?: @"?");
    } else {
        GC_LOG("AVAudioSession active — should survive backgrounding");
    }
}
