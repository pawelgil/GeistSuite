#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GeistWeakReference : NSObject

@property(nonatomic, weak, readonly, nullable) id object;

- (instancetype)initWithObject:(id)object;

@end

NS_ASSUME_NONNULL_END
