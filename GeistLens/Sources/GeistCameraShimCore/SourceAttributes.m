#import "SourceAttributes.h"

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

static BOOL isCompatibleInitializer(Method method) {
    return method &&
        method_getNumberOfArguments(method) == 3 &&
        hasReturnType(method, "@") &&
        hasType(method, 0, "@") &&
        hasType(method, 1, ":") &&
        hasType(method, 2, "@");
}

GeistCamSourceAttributes geistcam_resolveSourceAttributes(
    Class modernClass,
    CFStringRef legacyPropertyKey,
    CFStringRef modernPropertyKey
) {
    GeistCamSourceAttributes provider = {
        .mode = GeistCamSourceAttributesModeUnsupported,
        .propertyKey = NULL,
        .modernClass = Nil,
        .modernInit = NULL,
    };
    SEL selector = NSSelectorFromString(@"initWithAttributesDictionary:");
    Method method = modernClass ? class_getInstanceMethod(modernClass, selector) : NULL;
    if (modernPropertyKey && isCompatibleInitializer(method)) {
        IMP implementation = method_getImplementation(method);
        if (implementation) {
            provider.mode = GeistCamSourceAttributesModeModernObject;
            provider.propertyKey = modernPropertyKey;
            provider.modernClass = modernClass;
            provider.modernInit = (GeistCamSourceAttributesInitFn)implementation;
            return provider;
        }
    }
    if (legacyPropertyKey) {
        provider.mode = GeistCamSourceAttributesModeLegacyDictionary;
        provider.propertyKey = legacyPropertyKey;
    }
    return provider;
}

CFTypeRef geistcam_createSourceAttributes(
    GeistCamSourceAttributes provider,
    NSDictionary *dictionary
) {
    if (provider.mode == GeistCamSourceAttributesModeModernObject &&
        provider.modernClass && provider.modernInit) {
        id allocated = [provider.modernClass alloc];
        id attributes = provider.modernInit(
            allocated,
            NSSelectorFromString(@"initWithAttributesDictionary:"),
            dictionary
        );
        return attributes ? CFBridgingRetain(attributes) : NULL;
    }
    if (provider.mode == GeistCamSourceAttributesModeLegacyDictionary) {
        return CFBridgingRetain(dictionary);
    }
    return NULL;
}
