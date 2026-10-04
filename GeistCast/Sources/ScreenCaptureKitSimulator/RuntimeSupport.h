#pragma once

#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <objc/runtime.h>

static inline NSError *GSCKError(SCStreamErrorCode code, NSString *description) {
    return [NSError errorWithDomain:SCStreamErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

static inline void GSCKSetObject(id object, const void *key, id value) {
    objc_setAssociatedObject(object, key, value, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static inline id GSCKGetObject(id object, const void *key) {
    return objc_getAssociatedObject(object, key);
}

static inline UIScreen *GSCKActiveScreen(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) return ((UIWindowScene *)scene).screen;
    }
    return nil;
}

typedef struct {
    CGRect bounds;
    CGRect nativeBounds;
    CGFloat scale;
    BOOL available;
} GSCKScreenGeometry;

static inline GSCKScreenGeometry GSCKGetScreenGeometry(void) {
    __block GSCKScreenGeometry geometry = { .scale = 1 };
    void (^readGeometry)(void) = ^{
        UIScreen *screen = GSCKActiveScreen();
        if (screen) {
            geometry.bounds = screen.bounds;
            geometry.nativeBounds = screen.nativeBounds;
            geometry.scale = screen.scale;
            geometry.available = YES;
        }
    };
    if (NSThread.isMainThread) readGeometry();
    else dispatch_sync(dispatch_get_main_queue(), readGeometry);
    return geometry;
}
