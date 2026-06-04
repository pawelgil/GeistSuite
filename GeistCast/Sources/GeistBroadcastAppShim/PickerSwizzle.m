#import "PickerSwizzle.h"
#import "BroadcastDriver.h"
#import "ShimLog.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSArray *findButtons(id view) {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray *queue = [NSMutableArray arrayWithObject:view];
    Class buttonClass = NSClassFromString(@"UIButton");
    while (queue.count > 0) {
        id v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:buttonClass]) {
            [out addObject:v];
        }
        // Picker children may be UIRemoteView-hosted; KVC `subviews` is
        // not always honored there.
        NSArray *subs = nil;
        @try { subs = [v valueForKey:@"subviews"]; } @catch (NSException *e) {}
        if (subs) [queue addObjectsFromArray:subs];
    }
    return out;
}

static void dumpSubviewTree(id view, int depth) {
    if (!view || depth > 8) return;
    NSString *cls = NSStringFromClass([view class]);
    NSString *pad = [@"" stringByPaddingToLength:(NSUInteger)(depth * 2) withString:@" " startingAtIndex:0];
    GC_LOG("picker subview tree: %{public}@%{public}@", pad, cls);
    NSArray *subs = nil;
    @try { subs = [view valueForKey:@"subviews"]; } @catch (NSException *e) {}
    for (id sub in subs) {
        dumpSubviewTree(sub, depth + 1);
    }
}

// Marker to avoid double-attaching gesture recognizers when
// didMoveToWindow fires more than once for the same picker.
static const void *kPickerAttachedKey = "GeistCastPickerAttached";
static const void *kPickerPuppetKey = "GeistCastPickerPuppet";

// Some hosts open the picker programmatically by allocating a transient
// RPSystemBroadcastPickerView, iterating its direct subviews for a UIButton,
// and calling -sendActions: on it — without ever adding the picker to a
// window. didMoveToWindow never fires for that picker, and on simulator
// the inner button is hosted in a UIRemoteView (no direct UIButton subview
// either), so the iteration is a no-op. Plant a hidden non-interactive
// UIButton at depth 1 at -initWithFrame: time so the iteration finds
// something whose action routes to the driver.
static void installPuppetIfNeeded(id pickerView) {
    if (!pickerView) return;
    if (objc_getAssociatedObject(pickerView, kPickerPuppetKey)) return;

    Class buttonClass = NSClassFromString(@"UIButton");
    if (!buttonClass) return;

    id puppet = ((id (*)(id, SEL))objc_msgSend)(
        ((id (*)(Class, SEL))objc_msgSend)(buttonClass, sel_registerName("alloc")),
        sel_registerName("init"));
    ((void (*)(id, SEL, BOOL))objc_msgSend)(puppet, sel_registerName("setHidden:"), YES);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(puppet, sel_registerName("setUserInteractionEnabled:"), NO);
    typedef void (*AddFn)(id, SEL, id, SEL, UIControlEvents);
    ((AddFn)objc_msgSend)(puppet,
        sel_registerName("addTarget:action:forControlEvents:"),
        [GeistCastBroadcastDriver shared],
        sel_registerName("tap:"),
        UIControlEventTouchUpInside);
    ((void (*)(id, SEL, id))objc_msgSend)(pickerView, sel_registerName("addSubview:"), puppet);

    objc_setAssociatedObject(pickerView, kPickerPuppetKey,
                             puppet, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void attachToPicker(id pickerView) {
    if (!pickerView) return;
    if (objc_getAssociatedObject(pickerView, kPickerAttachedKey)) return;

    dumpSubviewTree(pickerView, 0);

    // RPSystemBroadcastPickerView's internal button may live in a
    // UIRemoteView, so a UIButton subview walk is unreliable. A gesture
    // recognizer on the picker itself sees every tap inside its bounds.
    Class tgrClass = NSClassFromString(@"UITapGestureRecognizer");
    if (!tgrClass) {
        GC_ERR("UITapGestureRecognizer class not found");
        return;
    }
    SEL initSel = sel_registerName("initWithTarget:action:");
    typedef id (*InitFn)(id, SEL, id, SEL);
    InitFn initFn = (InitFn)objc_msgSend;
    id recognizer = initFn([tgrClass alloc], initSel,
                           [GeistCastBroadcastDriver shared],
                           sel_registerName("tap:"));

    // We own the tap; the internal button must not forward to replayd.
    @try {
        [recognizer setValue:@YES forKey:@"cancelsTouchesInView"];
    } @catch (NSException *e) {}

    SEL addGR = sel_registerName("addGestureRecognizer:");
    typedef void (*AddGRFn)(id, SEL, id);
    AddGRFn addFn = (AddGRFn)objc_msgSend;
    addFn(pickerView, addGR, recognizer);

    // Force the picker view to accept touches even if its internal button
    // would normally swallow them before our recognizer sees them.
    SEL setUIE = sel_registerName("setUserInteractionEnabled:");
    typedef void (*SetUIEFn)(id, SEL, BOOL);
    SetUIEFn setFn = (SetUIEFn)objc_msgSend;
    setFn(pickerView, setUIE, YES);

    // Override the inner button's target/action too: wipe replayd's
    // handlers and install ours, so a direct tap on the button still
    // reaches the driver. Works alongside the gesture recognizer —
    // whichever fires first wins.
    NSArray *buttons = findButtons(pickerView);
    Class controlClass = NSClassFromString(@"UIControl");
    SEL removeAll = sel_registerName("removeTarget:action:forControlEvents:");
    SEL addTarget = sel_registerName("addTarget:action:forControlEvents:");
    int controlCount = 0;
    for (id btn in buttons) {
        if (![btn isKindOfClass:controlClass]) continue;
        typedef void (*RemoveFn)(id, SEL, id, SEL, UIControlEvents);
        RemoveFn removeFn = (RemoveFn)objc_msgSend;
        removeFn(btn, removeAll, nil, NULL, UIControlEventAllEvents);
        typedef void (*AddFn)(id, SEL, id, SEL, UIControlEvents);
        AddFn addFnB = (AddFn)objc_msgSend;
        addFnB(btn, addTarget,
              [GeistCastBroadcastDriver shared],
              sel_registerName("tap:"),
              UIControlEventTouchUpInside);
        controlCount++;
    }

    installPuppetIfNeeded(pickerView);

    objc_setAssociatedObject(pickerView, kPickerAttachedKey,
                             @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    GC_LOG("attached UITapGestureRecognizer + %d UIControl handler(s) + puppet", controlCount);
}

// RPSystemBroadcastPickerView's internal UIButton (which we redirect to
// the host control socket instead of replayd) is not populated at init —
// it appears when the view enters a window. Hooking didMoveToWindow is
// the earliest reliable point where the subview tree is walkable.

static SEL pickerSwizSel(void) {
    static SEL s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = sel_registerName("gc_didMoveToWindow"); });
    return s;
}

static void swiz_didMoveToWindow(id self, SEL _cmd) {
    // After method_exchangeImplementations, the original IMP lives under
    // pickerSwizSel(); invoking it via objc_msgSend dispatches correctly
    // whether the picker overrode the method itself or inherited it.
    typedef void (*Fn)(id, SEL);
    ((Fn)objc_msgSend)(self, pickerSwizSel());
    attachToPicker(self);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        attachToPicker(self);
    });
}

void GC_InstallPickerSwizzle(void) {
    Class picker = NSClassFromString(@"RPSystemBroadcastPickerView");
    if (!picker) return;
    SEL origSel = sel_registerName("didMoveToWindow");
    SEL swizSel = pickerSwizSel();
    Method origMethod = class_getInstanceMethod(picker, origSel);
    if (!origMethod) return;
    if (class_getInstanceMethod(picker, swizSel)) return;

    // Copy the (possibly inherited) IMP onto the picker class so we can
    // swap locally. If the picker already defines didMoveToWindow,
    // class_addMethod returns NO and its IMP stays in place.
    class_addMethod(picker, origSel,
                    method_getImplementation(origMethod),
                    method_getTypeEncoding(origMethod));
    class_addMethod(picker, swizSel,
                    (IMP)swiz_didMoveToWindow,
                    method_getTypeEncoding(origMethod));
    method_exchangeImplementations(
        class_getInstanceMethod(picker, origSel),
        class_getInstanceMethod(picker, swizSel)
    );
    GC_LOG("swizzled RPSystemBroadcastPickerView -didMoveToWindow");
}

static SEL pickerInitSwizSel(void) {
    static SEL s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = sel_registerName("gc_initWithFrame:"); });
    return s;
}

static id swiz_initWithFrame(id self, SEL _cmd, CGRect frame) {
    typedef id (*Fn)(id, SEL, CGRect);
    id result = ((Fn)objc_msgSend)(self, pickerInitSwizSel(), frame);
    if (result) installPuppetIfNeeded(result);
    return result;
}

void GC_InstallPickerInitSwizzle(void) {
    Class picker = NSClassFromString(@"RPSystemBroadcastPickerView");
    if (!picker) return;
    SEL origSel = sel_registerName("initWithFrame:");
    SEL swizSel = pickerInitSwizSel();
    Method origMethod = class_getInstanceMethod(picker, origSel);
    if (!origMethod) return;
    if (class_getInstanceMethod(picker, swizSel)) return;

    class_addMethod(picker, origSel,
                    method_getImplementation(origMethod),
                    method_getTypeEncoding(origMethod));
    class_addMethod(picker, swizSel,
                    (IMP)swiz_initWithFrame,
                    method_getTypeEncoding(origMethod));
    method_exchangeImplementations(
        class_getInstanceMethod(picker, origSel),
        class_getInstanceMethod(picker, swizSel)
    );
    GC_LOG("swizzled RPSystemBroadcastPickerView -initWithFrame:");
}

static IMP s_origSendAction = NULL;

static BOOL viewIsInsidePicker(id view) {
    Class pickerCls = NSClassFromString(@"RPSystemBroadcastPickerView");
    if (!pickerCls) return NO;
    id v = view;
    int depth = 0;
    while (v && depth++ < 50) {
        if ([v isKindOfClass:pickerCls]) return YES;
        @try { v = [v valueForKey:@"superview"]; } @catch (NSException *e) { v = nil; }
    }
    return NO;
}

// Fallback intercept: if the per-button addTarget swizzle missed a
// control inside the picker (e.g. one added after our subview walk), this
// global UIControl hook still redirects its action to the driver.
static BOOL swiz_sendAction(id self, SEL _cmd, SEL action, id target, id event) {
    if (viewIsInsidePicker(self)) {
        GC_LOG("control inside picker — diverting to driver");
        [[GeistCastBroadcastDriver shared] tap:self];
        return YES;
    }
    typedef BOOL (*Fn)(id, SEL, SEL, id, id);
    Fn fn = (Fn)s_origSendAction;
    return fn ? fn(self, _cmd, action, target, event) : NO;
}

void GC_InstallSendActionSwizzle(void) {
    Class ctrl = NSClassFromString(@"UIControl");
    if (!ctrl) return;
    SEL sel = sel_registerName("sendAction:to:forEvent:");
    Method m = class_getInstanceMethod(ctrl, sel);
    if (!m) return;
    if (s_origSendAction) return;
    s_origSendAction = method_getImplementation(m);
    class_replaceMethod(ctrl, sel,
                        (IMP)swiz_sendAction,
                        method_getTypeEncoding(m));
    GC_LOG("swizzled UIControl -sendAction:to:forEvent:");
}

// The didMoveToWindow swizzle only catches pickers added after it's
// installed; this scans the existing hierarchy for any picker views that
// already entered a window before then.
static void scanWindowForPickers(id view, Class pickerCls, int *count) {
    if (!view || !pickerCls) return;
    if ([view isKindOfClass:pickerCls]) {
        attachToPicker(view);
        (*count)++;
    }
    NSArray *subs = nil;
    @try { subs = [view valueForKey:@"subviews"]; } @catch (NSException *e) {}
    for (id sub in subs) {
        scanWindowForPickers(sub, pickerCls, count);
    }
}

void GC_ScanAllWindowsForPickers(void) {
    Class pickerCls = NSClassFromString(@"RPSystemBroadcastPickerView");
    if (!pickerCls) return;
    Class appCls = NSClassFromString(@"UIApplication");
    if (!appCls) return;
    id app = ((id (*)(Class, SEL))objc_msgSend)(appCls, sel_registerName("sharedApplication"));
    if (!app) return;
    NSArray *windows = nil;
    @try {
        windows = [app valueForKey:@"windows"];
    } @catch (NSException *e) {}
    if (!windows || windows.count == 0) {
        @try {
            NSArray *scenes = [app valueForKey:@"connectedScenes"];
            NSMutableArray *out = [NSMutableArray array];
            for (id scene in scenes) {
                @try {
                    NSArray *sceneWindows = [scene valueForKey:@"windows"];
                    if (sceneWindows) [out addObjectsFromArray:sceneWindows];
                } @catch (NSException *e) {}
            }
            windows = out;
        } @catch (NSException *e) {}
    }
    int count = 0;
    for (id w in windows) {
        scanWindowForPickers(w, pickerCls, &count);
    }
    if (count > 0) {
        GC_LOG("scan attached to %d existing picker view(s)", count);
    }
}
