#import "GMMediaFaults.h"
#import <objc/runtime.h>

static GMFaultController *s_controller;
static IMP s_writerStatus;
static IMP s_writerError;
static IMP s_finish;
static IMP s_finishAsync;
static IMP s_export;
static IMP s_exportStatus;
static IMP s_exportError;
static const void *s_publishedFailureKey = &s_publishedFailureKey;

static NSError *publishedFailure(id object) {
    return objc_getAssociatedObject(object, s_publishedFailureKey);
}

static NSInteger writerStatus(id object, SEL selector) {
    if (publishedFailure(object)) return AVAssetWriterStatusFailed;
    return ((NSInteger (*)(id, SEL))s_writerStatus)(object, selector);
}

static NSError *writerError(id object, SEL selector) {
    return publishedFailure(object) ?: ((NSError *(*)(id, SEL))s_writerError)(object, selector);
}

static BOOL finish(id object, SEL selector) {
    if (publishedFailure(object)) return NO;
    return ((BOOL (*)(id, SEL))s_finish)(object, selector);
}

static void finishAsync(id object, SEL selector, void (^completion)(void)) {
    if (publishedFailure(object)) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), completion);
        return;
    }
    ((void (*)(id, SEL, void (^)(void)))s_finishAsync)(object, selector, completion);
}

static void exportAsync(id object, SEL selector, void (^completion)(void)) {
    NSError *reservedFailure = [s_controller failureForExport:object];
    if (reservedFailure) {
        [object willChangeValueForKey:@"status"];
        [object willChangeValueForKey:@"error"];
        objc_setAssociatedObject(object, s_publishedFailureKey, reservedFailure, OBJC_ASSOCIATION_RETAIN);
        [object didChangeValueForKey:@"error"];
        [object didChangeValueForKey:@"status"];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), completion);
        return;
    }
    ((void (*)(id, SEL, void (^)(void)))s_export)(object, selector, completion);
}

static NSInteger exportStatus(id object, SEL selector) {
    if (publishedFailure(object)) return AVAssetExportSessionStatusFailed;
    return ((NSInteger (*)(id, SEL))s_exportStatus)(object, selector);
}

static NSError *exportError(id object, SEL selector) {
    return publishedFailure(object) ?: ((NSError *(*)(id, SEL))s_exportError)(object, selector);
}

static void replace(Class type, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(type, selector);
    if (!method) return;
    *original = method_getImplementation(method);
    class_replaceMethod(type, selector, replacement, method_getTypeEncoding(method));
}

@implementation GMMediaFaults
+ (GMFaultController *)controller { return s_controller; }

+ (void)installWithWriterErrorCode:(NSInteger)code underlyingCode:(NSInteger)underlyingCode exportHooks:(BOOL)exportHooks logger:(void (^)(NSString *))logger {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s_controller = [[GMFaultController alloc] initWithWriterErrorCode:code underlyingCode:underlyingCode logger:logger];
        replace(AVAssetWriter.class, @selector(status), (IMP)writerStatus, &s_writerStatus);
        replace(AVAssetWriter.class, @selector(error), (IMP)writerError, &s_writerError);
        replace(AVAssetWriter.class, @selector(finishWriting), (IMP)finish, &s_finish);
        replace(AVAssetWriter.class, @selector(finishWritingWithCompletionHandler:), (IMP)finishAsync, &s_finishAsync);
        if (exportHooks) {
            replace(AVAssetExportSession.class, @selector(exportAsynchronouslyWithCompletionHandler:), (IMP)exportAsync, &s_export);
            replace(AVAssetExportSession.class, @selector(status), (IMP)exportStatus, &s_exportStatus);
            replace(AVAssetExportSession.class, @selector(error), (IMP)exportError, &s_exportError);
        }
    });
}

+ (BOOL)rejectAppendForWriter:(AVAssetWriter *)writer mediaType:(NSString *)mediaType {
    if (!writer) return NO;
    @synchronized (writer) {
        if ([s_controller errorForObject:writer]) return YES;
        if (writer.status != AVAssetWriterStatusWriting) return NO;
        NSString *kind = [mediaType isEqual:AVMediaTypeVideo] ? @"video" : [mediaType isEqual:AVMediaTypeAudio] ? @"audio" : mediaType;
        NSError *reservedFailure = [s_controller failureForWriter:writer mediaType:kind];
        if (!reservedFailure) return NO;
        [writer willChangeValueForKey:@"status"];
        [writer willChangeValueForKey:@"error"];
        objc_setAssociatedObject(writer, s_publishedFailureKey, reservedFailure, OBJC_ASSOCIATION_RETAIN);
        [writer didChangeValueForKey:@"error"];
        [writer cancelWriting];
        [writer didChangeValueForKey:@"status"];
        return YES;
    }
}
@end
