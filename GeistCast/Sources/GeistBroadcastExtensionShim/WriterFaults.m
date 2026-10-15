#import "WriterFaults.h"
#import "GMMediaFaults.h"
#import "ShimLog.h"
#import <objc/runtime.h>

static NSMapTable *s_writers;
static IMP s_start;
static IMP s_addInput;
static IMP s_append;

static BOOL start(id writer, SEL selector) {
    BOOL result = ((BOOL (*)(id, SEL))s_start)(writer, selector);
    if (result) [[GMMediaFaults controller] writerStarted:writer];
    return result;
}

static void addInput(id writer, SEL selector, AVAssetWriterInput *input) {
    ((void (*)(id, SEL, id))s_addInput)(writer, selector, input);
    @synchronized (s_writers) { [s_writers setObject:writer forKey:input]; }
}

static BOOL append(AVAssetWriterInput *input, SEL selector, CMSampleBufferRef sample) {
    AVAssetWriter *writer;
    @synchronized (s_writers) { writer = [s_writers objectForKey:input]; }
    if ([GMMediaFaults rejectAppendForWriter:writer mediaType:input.mediaType]) return NO;
    return ((BOOL (*)(id, SEL, CMSampleBufferRef))s_append)(input, selector, sample);
}

void GC_InstallWriterFaults(void) {
    [GMMediaFaults installWithWriterErrorCode:-11819 underlyingCode:0 exportHooks:NO logger:^(NSString *message) {
        GC_LOG("%{public}@", message);
    }];
    s_writers = [NSMapTable weakToWeakObjectsMapTable];
    s_start = method_setImplementation(class_getInstanceMethod(AVAssetWriter.class, @selector(startWriting)), (IMP)start);
    s_addInput = method_setImplementation(class_getInstanceMethod(AVAssetWriter.class, @selector(addInput:)), (IMP)addInput);
    s_append = method_setImplementation(class_getInstanceMethod(AVAssetWriterInput.class, @selector(appendSampleBuffer:)), (IMP)append);
}
