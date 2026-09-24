#import "GeistWeakReference.h"

@interface GeistWeakReference ()

@property(nonatomic, weak, readwrite, nullable) id object;

@end


@implementation GeistWeakReference

- (instancetype)initWithObject:(id)object {
    self = [super init];
    if (self) {
        _object = object;
    }
    return self;
}

@end
