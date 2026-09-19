#pragma once

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

typedef id _Nullable GeistCamSourceAttributesInitFunction(
    id _Nonnull NS_RELEASES_ARGUMENT,
    SEL _Nonnull,
    NSDictionary * _Nonnull
) NS_RETURNS_RETAINED;
typedef GeistCamSourceAttributesInitFunction *GeistCamSourceAttributesInitFn;

typedef enum {
    GeistCamSourceAttributesModeUnsupported = 0,
    GeistCamSourceAttributesModeLegacyDictionary = 1,
    GeistCamSourceAttributesModeModernObject = 2,
} GeistCamSourceAttributesMode;

typedef struct {
    GeistCamSourceAttributesMode mode;
    CFStringRef _Nullable propertyKey;
    Class _Nullable modernClass;
    GeistCamSourceAttributesInitFn _Nullable modernInit;
} GeistCamSourceAttributes;

GeistCamSourceAttributes geistcam_resolveSourceAttributes(
    Class _Nullable modernClass,
    CFStringRef _Nullable legacyPropertyKey,
    CFStringRef _Nullable modernPropertyKey
);

CFTypeRef _Nullable geistcam_createSourceAttributes(
    GeistCamSourceAttributes provider,
    NSDictionary * _Nonnull dictionary
) CF_RETURNS_RETAINED;
