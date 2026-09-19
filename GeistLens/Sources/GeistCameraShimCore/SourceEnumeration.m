#import "SourceEnumeration.h"

static BOOL hasType(Method method, unsigned int index, const char *expected) {
    char *actual = method_copyArgumentType(method, index);
    BOOL matches = actual && strcmp(actual, expected) == 0;
    free(actual);
    return matches;
}

static BOOL hasReturnType(Method method, const char *expected) {
    char *actual = method_copyReturnType(method);
    BOOL matches = actual && strcmp(actual, expected) == 0;
    free(actual);
    return matches;
}

static BOOL isCompatibleManagerMethod(Method method) {
    return method &&
        method_getNumberOfArguments(method) == 3 &&
        hasReturnType(method, "@") &&
        hasType(method, 0, "@") &&
        hasType(method, 1, ":") &&
        hasType(method, 2, "i");
}

static Method methodDeclaredByClass(Class cls, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method declared = NULL;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) {
            declared = methods[index];
            break;
        }
    }
    free(methods);
    return declared;
}

GeistCamSourceEnumeration geistcam_installSourceEnumerationHook(
    Class managerClass,
    GeistCamLegacyCopySourcesFn legacy,
    IMP replacement
) {
    GeistCamSourceEnumeration provider = {
        .mode = GeistCamSourceEnumerationModeUnsupported,
        .managerOriginal = NULL,
        .legacy = legacy,
    };
    SEL selector = NSSelectorFromString(@"copySourcesWithType:");
    Method method = managerClass ? class_getInstanceMethod(managerClass, selector) : NULL;
    if (replacement && isCompatibleManagerMethod(method)) {
        IMP original = method_getImplementation(method);
        Method declared = methodDeclaredByClass(managerClass, selector);
        BOOL installed = declared
            ? method_setImplementation(declared, replacement) != NULL
            : class_addMethod(managerClass, selector, replacement, method_getTypeEncoding(method));
        if (installed) {
            provider.mode = GeistCamSourceEnumerationModeManager;
            provider.managerOriginal = (GeistCamManagerCopySourcesFn)original;
            return provider;
        }
    }
    if (legacy) provider.mode = GeistCamSourceEnumerationModeLegacy;
    return provider;
}

NSArray *geistcam_copyOriginalSources(
    GeistCamSourceEnumeration provider,
    id receiver,
    SEL selector,
    int32_t sourceType
) {
    if (provider.mode == GeistCamSourceEnumerationModeManager && provider.managerOriginal) {
        return provider.managerOriginal(receiver, selector, sourceType);
    }
    if (provider.mode == GeistCamSourceEnumerationModeLegacy && provider.legacy) {
        CFArrayRef sources = provider.legacy();
        return sources ? CFBridgingRelease(sources) : nil;
    }
    return nil;
}
