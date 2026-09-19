#import "SerializedSourceProvider.h"

@implementation GeistCamSerializedSourceProvider {
    NSLock *_lock;
    NSArray *_cachedSources;
}

- (instancetype)init {
    self = [super init];
    if (self) _lock = [NSLock new];
    return self;
}

- (NSArray *)copySourcesWithLoader:(GeistCamSourceLoader)loader {
    [_lock lock];
    @try {
        if (_cachedSources) return _cachedSources;
        BOOL shouldCache = NO;
        NSArray *sources = loader(&shouldCache);
        if (shouldCache && sources) _cachedSources = sources;
        return sources;
    } @finally {
        [_lock unlock];
    }
}

@end
