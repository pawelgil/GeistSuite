#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface GMFaultController : NSObject
- (instancetype)initWithWriterErrorCode:(NSInteger)code underlyingCode:(NSInteger)underlyingCode logger:(void (^)(NSString *))logger;
- (NSDictionary *)handle:(NSDictionary *)request;
- (void)writerStarted:(id)writer;
- (nullable NSError *)failureForWriter:(id)writer mediaType:(NSString *)mediaType;
- (nullable NSError *)failureForExport:(id)session;
- (nullable NSError *)errorForObject:(id)object;
@end
NS_ASSUME_NONNULL_END
