#import "AppGroupContainerAliases.h"
#import "ShimLog.h"
#import <CommonCrypto/CommonDigest.h>
#import <TargetConditionals.h>
#import <objc/runtime.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static const size_t GCReservedSocketSuffixBytes = 40;
static const size_t GCContainerPathBudget = sizeof(((struct sockaddr_un *)0)->sun_path) - 1 - GCReservedSocketSuffixBytes;

@interface GCAppGroupContainerAliases ()
@property(nonatomic, readonly) NSURL *directoryURL;
@end

@implementation GCAppGroupContainerAliases

+ (void)install {
#if TARGET_OS_SIMULATOR
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SEL selector = @selector(containerURLForSecurityApplicationGroupIdentifier:);
        Method method = class_getInstanceMethod(NSFileManager.class, selector);
        if (!method) {
            GC_ERR("app-group container lookup unavailable");
            return;
        }
        NSURL *(*original)(NSFileManager *, SEL, NSString *) = (void *)method_getImplementation(method);
        NSURL *root = [NSURL fileURLWithPath:[NSString stringWithFormat:@"/tmp/gc-%u", geteuid()] isDirectory:YES];
        GCAppGroupContainerAliases *aliases = [[self alloc] initWithDirectoryURL:root];
        IMP replacement = imp_implementationWithBlock(^NSURL *(NSFileManager *manager, NSString *identifier) {
            return [aliases containerURLForURL:original(manager, selector, identifier)];
        });
        method_setImplementation(method, replacement);
        GC_LOG("installed short app-group container aliases");
    });
#endif
}

- (instancetype)initWithDirectoryURL:(NSURL *)directoryURL {
    self = [super init];
    if (self) {
        _directoryURL = [directoryURL copy];
    }
    return self;
}

- (NSURL *)containerURLForURL:(NSURL *)containerURL {
    if (!containerURL.isFileURL || strlen(containerURL.fileSystemRepresentation) <= GCContainerPathBudget) {
        return containerURL;
    }
    char canonicalPath[PATH_MAX];
    if (realpath(containerURL.fileSystemRepresentation, canonicalPath)) {
        NSURL *aliasURL = [self aliasURLForCanonicalPath:canonicalPath];
        if (aliasURL) {
            return aliasURL;
        }
    }
    GC_ERR("app-group alias unavailable errno=%d path=%{public}@", errno, containerURL.path);
    return containerURL;
}

- (NSURL *)aliasURLForCanonicalPath:(const char *)canonicalPath {
    NSString *name = [self aliasNameForPath:canonicalPath];
    NSURL *aliasURL = [self.directoryURL URLByAppendingPathComponent:name isDirectory:YES];
    if (!aliasURL.isFileURL || strlen(aliasURL.fileSystemRepresentation) > GCContainerPathBudget) {
        errno = ENAMETOOLONG;
        return nil;
    }
    return [self ensureAlias:name.fileSystemRepresentation target:canonicalPath] ? aliasURL : nil;
}

- (NSString *)aliasNameForPath:(const char *)path {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(path, (CC_LONG)strlen(path), digest);
    char name[33];
    for (size_t index = 0; index < 16; index++) {
        snprintf(name + index * 2, 3, "%02x", digest[index]);
    }
    return [NSString stringWithUTF8String:name];
}

- (BOOL)ensureAlias:(const char *)name target:(const char *)target {
    int directoryDescriptor = [self openPrivateAliasDirectory];
    if (directoryDescriptor < 0) {
        return NO;
    }
    BOOL ready = [self createOrValidateAlias:name target:target directoryDescriptor:directoryDescriptor];
    int savedErrno = errno;
    close(directoryDescriptor);
    errno = savedErrno;
    return ready;
}

- (int)openPrivateAliasDirectory {
    const char *path = self.directoryURL.fileSystemRepresentation;
    if (mkdir(path, 0700) != 0 && errno != EEXIST) {
        return -1;
    }
    int directoryDescriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directoryDescriptor < 0) {
        return -1;
    }
    struct stat info;
    if (fstat(directoryDescriptor, &info) == 0 && info.st_uid == geteuid() && (info.st_mode & 0777) == 0700) {
        return directoryDescriptor;
    }
    close(directoryDescriptor);
    errno = EACCES;
    return -1;
}

- (BOOL)createOrValidateAlias:(const char *)name target:(const char *)target directoryDescriptor:(int)directoryDescriptor {
    struct stat info;
    if (stat(target, &info) != 0) {
        return NO;
    }
    if (!S_ISDIR(info.st_mode)) {
        errno = ENOTDIR;
        return NO;
    }
    if (symlinkat(target, directoryDescriptor, name) == 0) {
        return YES;
    }
    if (errno != EEXIST) {
        return NO;
    }
    return [self validateExistingAlias:name target:target directoryDescriptor:directoryDescriptor];
}

- (BOOL)validateExistingAlias:(const char *)name target:(const char *)target directoryDescriptor:(int)directoryDescriptor {
    char existing[PATH_MAX];
    ssize_t length = readlinkat(directoryDescriptor, name, existing, sizeof(existing));
    if (length >= 0 && (size_t)length == strlen(target) && memcmp(existing, target, (size_t)length) == 0) {
        return YES;
    }
    errno = EEXIST;
    return NO;
}

@end
