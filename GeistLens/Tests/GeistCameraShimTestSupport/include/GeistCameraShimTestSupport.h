#pragma once

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "SourceAttributes.h"
#import "SourceEnumeration.h"

NS_ASSUME_NONNULL_BEGIN

typedef enum {
    GeistCamTestAttributesBehaviorReturnsReceiver = 0,
    GeistCamTestAttributesBehaviorReturnsNil = 1,
    GeistCamTestAttributesBehaviorReturnsReplacement = 2,
} GeistCamTestAttributesBehavior;

Class GeistCamTestMakeAttributesClass(
    const char * _Nullable typeEncoding,
    GeistCamTestAttributesBehavior behavior
);
BOOL GeistCamTestLastConsumedAttributesReceiverWasDeallocated(void);
Class GeistCamTestMakeManagerClass(const char * _Nullable typeEncoding);
Class GeistCamTestMakeManagerSubclass(Class superclass);
id GeistCamTestMakeManagerReceiver(Class managerClass, id token);
IMP GeistCamTestReplacementIMP(void);
NSArray *GeistCamTestInvokeManager(id receiver, int32_t sourceType) NS_RETURNS_RETAINED;
CFArrayRef GeistCamTestCopyLegacySources(void) CF_RETURNS_RETAINED;
GeistCamLegacyCopySourcesFn GeistCamTestLegacySourceCopier(void);
GeistCamSourceAttributes GeistCamTestResolveSourceAttributes(
    Class _Nullable modernClass,
    NSString * _Nullable legacyPropertyKey,
    NSString * _Nullable modernPropertyKey
);
id _Nullable GeistCamTestCreateSourceAttributes(
    GeistCamSourceAttributes provider,
    NSDictionary *dictionary
);
NSString * _Nullable GeistCamTestSourceAttributesPropertyKey(GeistCamSourceAttributes provider);
NSDictionary * _Nullable GeistCamTestAttributesDictionary(id attributes);

NS_ASSUME_NONNULL_END
