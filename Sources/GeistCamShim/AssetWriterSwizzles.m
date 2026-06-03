#import "AssetWriterSwizzles.h"
#import "Provenance.h"
#import "RecordingState.h"
#import "Util.h"
#import "WriterTracker.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <pthread.h>

// AVAssetWriterInput has no public back-reference to its writer. We populate
// this map at addInput: time so the appendSampleBuffer swizzle can resolve the
// parent writer from a tagged buffer's input.
static NSMapTable *s_inputToWriter;
static pthread_mutex_t s_mapMutex = PTHREAD_MUTEX_INITIALIZER;

static IMP s_origStartWriting;
static IMP s_origAddInput;
static IMP s_origInputAppendSampleBuffer;

static BOOL swiz_writer_startWriting(id self, SEL _cmd) {
    installWriterTracker(self);
    BOOL ok = s_origStartWriting
        ? ((BOOL(*)(id, SEL))s_origStartWriting)(self, _cmd)
        : YES;
    geistcam_debugf("AVAssetWriter startWriting: writer=%p url=%s ok=%d",
                     self, [(AVAssetWriter *)self outputURL].path.UTF8String ?: "(nil)", ok);
    return ok;
}

static void swiz_writer_addInput(id self, SEL _cmd, AVAssetWriterInput *input) {
    if (s_origAddInput) ((void(*)(id, SEL, AVAssetWriterInput *))s_origAddInput)(self, _cmd, input);
    if (!input) return;
    pthread_mutex_lock(&s_mapMutex);
    [s_inputToWriter setObject:self forKey:input];
    pthread_mutex_unlock(&s_mapMutex);
}

static BOOL swiz_input_appendSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sb) {
    if (sb && sampleBufferHasOurProvenance(sb)) {
        AVAssetWriter *writer = writerForInput(self);
        if (writer) recordingAssetWriterFlagged(writer);
    }
    return s_origInputAppendSampleBuffer
        ? ((BOOL(*)(id, SEL, CMSampleBufferRef))s_origInputAppendSampleBuffer)(self, _cmd, sb)
        : YES;
}

void installAssetWriterSwizzles(void) {
    if (!s_inputToWriter) {
        s_inputToWriter = [NSMapTable mapTableWithKeyOptions:NSMapTableWeakMemory
                                                valueOptions:NSMapTableWeakMemory];
    }
    swizzleMethod(@"AVAssetWriter", @selector(startWriting),
                  (IMP)swiz_writer_startWriting, &s_origStartWriting);
    swizzleMethod(@"AVAssetWriter", @selector(addInput:),
                  (IMP)swiz_writer_addInput, &s_origAddInput);
    swizzleMethod(@"AVAssetWriterInput", @selector(appendSampleBuffer:),
                  (IMP)swiz_input_appendSampleBuffer, &s_origInputAppendSampleBuffer);
}

AVAssetWriter *writerForInput(AVAssetWriterInput *input) {
    if (!input || !s_inputToWriter) return nil;
    pthread_mutex_lock(&s_mapMutex);
    AVAssetWriter *writer = [s_inputToWriter objectForKey:input];
    pthread_mutex_unlock(&s_mapMutex);
    return writer;
}
