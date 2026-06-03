#import "HandlerResolver.h"

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdlib.h>

BOOL GC_IsSubclassOf(Class cls, Class base) {
    if (!cls || !base) return NO;
    Class c = cls;
    while (c) { if (c == base) return YES; c = class_getSuperclass(c); }
    return NO;
}

// Swift class names are emitted as "$(MODULE).Class" in Info.plist;
// the unqualified form is sometimes resolvable when the qualified
// one isn't.
static Class GC_ResolveClassByName(NSString *name) {
    Class c = NSClassFromString(name);
    if (c) return c;
    NSArray *parts = [name componentsSeparatedByString:@"."];
    if (parts.count >= 2) {
        c = NSClassFromString(parts.lastObject);
        if (c) return c;
    }
    return nil;
}

Class GC_FindBroadcastHandlerClass(void) {
    const char *envClass = getenv("GEISTCAST_HANDLER_CLASS");
    if (envClass && envClass[0]) {
        Class c = GC_ResolveClassByName([NSString stringWithUTF8String:envClass]);
        if (c) return c;
    }
    NSBundle *main = [NSBundle mainBundle];
    NSDictionary *ext = main.infoDictionary[@"NSExtension"];
    NSString *principalName = ext[@"NSExtensionPrincipalClass"];
    if (principalName) {
        Class c = GC_ResolveClassByName(principalName);
        if (c) return c;
    }
    Class base = NSClassFromString(@"RPBroadcastSampleHandler");
    if (!base) return nil;
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return nil;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
    int got = objc_getClassList(classes, count);
    Class found = NULL;
    for (int i = 0; i < got; ++i) {
        Class c = classes[i];
        if (c == base) continue;
        if (GC_IsSubclassOf(c, base)) { found = c; break; }
    }
    free(classes);
    return found;
}
