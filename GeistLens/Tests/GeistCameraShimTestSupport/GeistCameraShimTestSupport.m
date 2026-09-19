#import "GeistCameraShimTestSupport.h"
#import "SourceEnumeration.h"
#import <objc/message.h>
#import <objc/runtime.h>

static char receiverTokenKey;
static char attributesDictionaryKey;
static char attributesBehaviorKey;
static __weak id lastConsumedAttributesReceiver;
static NSMutableArray<NSString *> *retainedPropertyKeys;

static NSString *uniqueClassName(NSString *prefix) {
    NSString *identifier = [NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
    return [prefix stringByAppendingString:identifier];
}

static CFStringRef retainedPropertyKey(NSString *key) {
    if (!key) return NULL;
    @synchronized (NSObject.class) {
        if (!retainedPropertyKeys) retainedPropertyKeys = [NSMutableArray array];
        NSString *retained = [key copy];
        [retainedPropertyKeys addObject:retained];
        return (__bridge CFStringRef)retained;
    }
}

static id initWithAttributesDictionary(id NS_RELEASES_ARGUMENT receiver,
                                       SEL selector,
                                       NSDictionary *dictionary) NS_RETURNS_RETAINED;
static id initWithAttributesDictionary(id NS_RELEASES_ARGUMENT receiver,
                                       SEL selector,
                                       NSDictionary *dictionary) {
    lastConsumedAttributesReceiver = receiver;
    GeistCamTestAttributesBehavior behavior = (GeistCamTestAttributesBehavior)
        [objc_getAssociatedObject(object_getClass(receiver), &attributesBehaviorKey) integerValue];
    if (behavior == GeistCamTestAttributesBehaviorReturnsNil) return nil;
    id result = behavior == GeistCamTestAttributesBehaviorReturnsReplacement ? [NSObject new] : receiver;
    objc_setAssociatedObject(result,
                             &attributesDictionaryKey,
                             dictionary,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return result;
}

static NSArray *copySources(id receiver, SEL selector, int32_t sourceType) NS_RETURNS_RETAINED;
static NSArray *copySources(id receiver, SEL selector, int32_t sourceType) {
    id token = objc_getAssociatedObject(receiver, &receiverTokenKey) ?: @"missing-token";
    return [[NSArray alloc] initWithObjects:token, NSStringFromSelector(selector), @(sourceType), nil];
}

static NSArray *replacement(id receiver, SEL selector, int32_t sourceType) NS_RETURNS_RETAINED;
static NSArray *replacement(id receiver, SEL selector, int32_t sourceType) {
    return [[NSArray alloc] initWithObjects:@"replacement", NSStringFromSelector(selector), @(sourceType), nil];
}

Class GeistCamTestMakeAttributesClass(
    const char *typeEncoding,
    GeistCamTestAttributesBehavior behavior
) {
    NSString *name = uniqueClassName(@"GeistCamTestAttributes_");
    Class attributesClass = objc_allocateClassPair(NSObject.class, name.UTF8String, 0);
    if (!attributesClass) return Nil;
    if (typeEncoding) {
        class_addMethod(attributesClass,
                        NSSelectorFromString(@"initWithAttributesDictionary:"),
                        (IMP)initWithAttributesDictionary,
                        typeEncoding);
    }
    objc_registerClassPair(attributesClass);
    objc_setAssociatedObject(attributesClass,
                             &attributesBehaviorKey,
                             @(behavior),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return attributesClass;
}

BOOL GeistCamTestLastConsumedAttributesReceiverWasDeallocated(void) {
    return lastConsumedAttributesReceiver == nil;
}

Class GeistCamTestMakeManagerClass(const char *typeEncoding) {
    NSString *name = uniqueClassName(@"GeistCamTestManager_");
    Class managerClass = objc_allocateClassPair(NSObject.class, name.UTF8String, 0);
    if (!managerClass) return Nil;
    if (typeEncoding) {
        class_addMethod(managerClass,
                        NSSelectorFromString(@"copySourcesWithType:"),
                        (IMP)copySources,
                        typeEncoding);
    }
    objc_registerClassPair(managerClass);
    return managerClass;
}

Class GeistCamTestMakeManagerSubclass(Class superclass) {
    NSString *name = uniqueClassName(@"GeistCamTestManagerSubclass_");
    Class managerClass = objc_allocateClassPair(superclass, name.UTF8String, 0);
    if (!managerClass) return Nil;
    objc_registerClassPair(managerClass);
    return managerClass;
}

id GeistCamTestMakeManagerReceiver(Class managerClass, id token) {
    id receiver = [managerClass new];
    objc_setAssociatedObject(receiver, &receiverTokenKey, token, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return receiver;
}

IMP GeistCamTestReplacementIMP(void) {
    return (IMP)replacement;
}

NSArray *GeistCamTestInvokeManager(id receiver, int32_t sourceType) {
    SEL selector = NSSelectorFromString(@"copySourcesWithType:");
    GeistCamManagerCopySourcesFn send = (void *)objc_msgSend;
    return send(receiver, selector, sourceType);
}

CFArrayRef GeistCamTestCopyLegacySources(void) {
    return CFBridgingRetain(@[@"legacy"]);
}

GeistCamLegacyCopySourcesFn GeistCamTestLegacySourceCopier(void) {
    return GeistCamTestCopyLegacySources;
}

GeistCamSourceAttributes GeistCamTestResolveSourceAttributes(
    Class modernClass,
    NSString *legacyPropertyKey,
    NSString *modernPropertyKey
) {
    return geistcam_resolveSourceAttributes(
        modernClass,
        retainedPropertyKey(legacyPropertyKey),
        retainedPropertyKey(modernPropertyKey)
    );
}

id GeistCamTestCreateSourceAttributes(
    GeistCamSourceAttributes provider,
    NSDictionary *dictionary
) {
    CFTypeRef value = geistcam_createSourceAttributes(provider, dictionary);
    return value ? CFBridgingRelease(value) : nil;
}

NSString *GeistCamTestSourceAttributesPropertyKey(GeistCamSourceAttributes provider) {
    return (__bridge NSString *)provider.propertyKey;
}

NSDictionary *GeistCamTestAttributesDictionary(id attributes) {
    return objc_getAssociatedObject(attributes, &attributesDictionaryKey);
}
