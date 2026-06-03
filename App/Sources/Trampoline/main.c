// LaunchServices lookup survives the user moving the .app — a baked symlink
// would dangle.

#include <CoreServices/CoreServices.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    CFArrayRef urls = LSCopyApplicationURLsForBundleIdentifier(
        CFSTR("com.geistlens.geistlens"), NULL);
    if (!urls || CFArrayGetCount(urls) == 0) {
        fprintf(stderr, "geistlens: GeistLens.app not found. Open it once, then retry.\n");
        if (urls) CFRelease(urls);
        return 1;
    }
    CFURLRef appURL = (CFURLRef)CFArrayGetValueAtIndex(urls, 0);
    char appPath[PATH_MAX];
    if (!CFURLGetFileSystemRepresentation(appURL, true, (UInt8 *)appPath, PATH_MAX)) {
        CFRelease(urls);
        fprintf(stderr, "geistlens: could not resolve GeistLens.app path\n");
        return 1;
    }
    CFRelease(urls);

    char binPath[PATH_MAX];
    int n = snprintf(binPath, sizeof(binPath),
                     "%s/Contents/SharedSupport/geistlens", appPath);
    if (n < 0 || n >= (int)sizeof(binPath)) {
        fprintf(stderr, "geistlens: app path too long\n");
        return 1;
    }

    execv(binPath, argv);
    fprintf(stderr, "geistlens: exec %s failed: %s\n", binPath, strerror(errno));
    return 1;
}
