#pragma once

#import <UIKit/UIKit.h>

// True when the running iOS exposes `UIGlassEffect` AND the host app
// hasn't opted out via `UIDesignRequiresCompatibility` in its Info.plist.
// Returns false unconditionally when this code is compiled against an
// SDK older than iOS 26 — the `UIGlassEffect` class symbol isn't even
// declared there, so the call sites guarded by this also have to be
// `#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 260000` to compile clean.
static inline BOOL HostSupportsGlassEffect(void) {
#if __IPHONE_OS_VERSION_MAX_ALLOWED < 260000
    return NO;
#else
    if (!NSClassFromString(@"UIGlassEffect")) return NO;
    NSNumber *optOut = [[NSBundle mainBundle]
        objectForInfoDictionaryKey:@"UIDesignRequiresCompatibility"];
    return !(optOut && [optOut boolValue]);
#endif
}
