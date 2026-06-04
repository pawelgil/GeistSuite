#import "ShimLog.h"

#import <Foundation/Foundation.h>

// NSExtensionMain crashes in _xpc_copy_xpcservice_dictionary without
// pluginkit's XPC service to talk to. Replace it with a runloop that
// keeps the process alive while the lifecycle driver runs in the
// background and calls _exit() when finished.
#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { \
        const void *replacement; \
        const void *replacee; \
    } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(unsigned long)&_replacement, \
        (const void *)(unsigned long)&_replacee \
    };

extern int NSExtensionMain(int argc, char *argv[]);

static int GeistCast_NSExtensionMain(int argc, char *argv[]) {
    (void)argc; (void)argv;
    GC_LOG("NSExtensionMain interposed — entering managed runloop");
    @autoreleasepool {
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}

DYLD_INTERPOSE(GeistCast_NSExtensionMain, NSExtensionMain)
