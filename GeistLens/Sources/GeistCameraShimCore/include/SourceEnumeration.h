#pragma once

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

typedef NSArray * _Nullable GeistCamManagerCopySourcesFunction(
    id _Nonnull,
    SEL _Nonnull,
    int32_t
) NS_RETURNS_RETAINED;
typedef GeistCamManagerCopySourcesFunction *GeistCamManagerCopySourcesFn;

typedef CFArrayRef _Nullable GeistCamLegacyCopySourcesFunction(void);
typedef GeistCamLegacyCopySourcesFunction *GeistCamLegacyCopySourcesFn;

typedef enum {
    GeistCamSourceEnumerationModeUnsupported = 0,
    GeistCamSourceEnumerationModeLegacy = 1,
    GeistCamSourceEnumerationModeManager = 2,
} GeistCamSourceEnumerationMode;

typedef struct {
    GeistCamSourceEnumerationMode mode;
    GeistCamManagerCopySourcesFn _Nullable managerOriginal;
    GeistCamLegacyCopySourcesFn _Nullable legacy;
} GeistCamSourceEnumeration;

GeistCamSourceEnumeration geistcam_installSourceEnumerationHook(
    Class _Nullable managerClass,
    GeistCamLegacyCopySourcesFn _Nullable legacy,
    IMP _Nullable replacement
);

NSArray * _Nullable geistcam_copyOriginalSources(
    GeistCamSourceEnumeration provider,
    id _Nullable receiver,
    SEL _Nullable selector,
    int32_t sourceType
) NS_RETURNS_RETAINED;
