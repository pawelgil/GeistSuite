#ifndef SECURITY_PRIVATE_H
#define SECURITY_PRIVATE_H

#import <Security/Security.h>

CF_EXTERN_C_BEGIN

typedef struct __SecCodeSigner *SecCodeSignerRef;

OSStatus SecCodeSignerCreate(CFDictionaryRef parameters,
                              SecCSFlags flags,
                              SecCodeSignerRef _Nullable * _Nonnull signer);

OSStatus SecCodeSignerAddSignatureWithErrors(SecCodeSignerRef signer,
                                              SecStaticCodeRef code,
                                              SecCSFlags flags,
                                              CFErrorRef _Nullable * _Nullable errors);

extern const CFStringRef kSecCodeSignerIdentity;
extern const CFStringRef kSecCodeSignerEntitlements;
extern const CFStringRef kSecCodeSignerFlags;

CF_EXTERN_C_END

#endif
