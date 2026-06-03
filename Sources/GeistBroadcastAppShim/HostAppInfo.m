#import "HostAppInfo.h"

NSString *GC_HostAppDisplayName(void) {
    NSDictionary *info = [NSBundle mainBundle].infoDictionary;
    return info[@"CFBundleDisplayName"]
        ?: info[@"CFBundleName"]
        ?: [NSBundle mainBundle].bundleIdentifier
        ?: @"App";
}

UIImage *GC_HostAppIcon(void) {
    NSDictionary *info = [NSBundle mainBundle].infoDictionary;
    NSDictionary *icons = info[@"CFBundleIcons"];
    NSDictionary *primary = icons[@"CFBundlePrimaryIcon"];
    NSArray<NSString *> *files = primary[@"CFBundleIconFiles"];
    // Last entry is conventionally the highest-resolution variant.
    for (NSString *name in files.reverseObjectEnumerator) {
        UIImage *img = [UIImage imageNamed:name];
        if (img) return img;
    }
    return nil;
}
