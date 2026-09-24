#import "FeedThread.h"
#import "FrameSocket.h"
#import "ShimLog.h"

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>

static id gBroadcastHandler = nil;
static volatile atomic_bool gFeedRunning = ATOMIC_VAR_INIT(false);
static BOOL gFeedPaused = NO;
static NSInteger gMicDeliveryMode = 0;
static pthread_mutex_t gDeliveryLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_t gFeedThread;
static int64_t gFrameCount = 0;

static void *FeedThreadMain(void *arg) {
    (void)arg;
    GC_LOG("feed thread started");
    int fd = GC_OpenFrameSocket();
    if (fd < 0) {
        GC_ERR("frame socket connect failed; feed thread exiting");
        return NULL;
    }
    while (atomic_load(&gFeedRunning)) {
        if (!gBroadcastHandler) break;
        @autoreleasepool {
            GCDeliveredSample delivered = GC_ReadNextSample(fd, NO);
            if (!delivered.sampleBuffer) {
                if (!atomic_load(&gFeedRunning)) break;
                GC_ERR("read next sample failed; backing off 200ms");
                usleep(200 * 1000);
                fd = GC_OpenFrameSocket();
                if (fd < 0) {
                    GC_ERR("reconnect failed; feed thread exiting");
                    break;
                }
                continue;
            }
            pthread_mutex_lock(&gDeliveryLock);
            BOOL withheldMic = gMicDeliveryMode == 2 && delivered.type == GCFeedSampleBufferTypeAudioMic;
            if (gFeedPaused || withheldMic) {
                CFRelease(delivered.sampleBuffer);
                pthread_mutex_unlock(&gDeliveryLock);
                continue;
            }
            if (gMicDeliveryMode == 1 && delivered.type == GCFeedSampleBufferTypeAudioMic) {
                CMSampleBufferRef unready = GC_CopySampleWithDataReadiness(delivered.sampleBuffer, NO);
                if (unready) {
                    CFRelease(delivered.sampleBuffer);
                    delivered.sampleBuffer = unready;
                }
            }
            id handler = gBroadcastHandler;
            SEL sel = sel_registerName("processSampleBuffer:withType:");
            IMP imp = [handler methodForSelector:sel];
            if (imp) {
                typedef void (*Fn)(id, SEL, CMSampleBufferRef, NSInteger);
                Fn fn = (Fn)imp;
                fn(handler, sel, delivered.sampleBuffer, (NSInteger)delivered.type);
                gFrameCount++;
                if ((gFrameCount % 30) == 0) {
                    GC_LOG("fed %lld samples (last type=%ld)",
                           gFrameCount, (long)delivered.type);
                }
            }
            CFRelease(delivered.sampleBuffer);
            pthread_mutex_unlock(&gDeliveryLock);
        }
    }
    GC_LOG("feed thread exiting after %lld samples", gFrameCount);
    return NULL;
}

void GC_StartFeedThread(id broadcastHandler) {
    gBroadcastHandler = broadcastHandler;
    gFrameCount = 0;
    pthread_mutex_lock(&gDeliveryLock);
    gFeedPaused = NO;
    gMicDeliveryMode = 0;
    pthread_mutex_unlock(&gDeliveryLock);
    atomic_store(&gFeedRunning, true);
    pthread_create(&gFeedThread, NULL, FeedThreadMain, NULL);
}

void GC_StopFeedThread(void) {
    atomic_store(&gFeedRunning, false);
    // Drop the frame socket BEFORE joining: the feed thread is parked
    // inside a blocking read() on it and won't notice gFeedRunning until
    // that read returns. shutdown(SHUT_RDWR) inside GC_DropFrameClient
    // unblocks it.
    GC_DropFrameClient();
    if (gBroadcastHandler) {
        pthread_join(gFeedThread, NULL);
    }
    gBroadcastHandler = nil;
}

void GC_SetFeedPaused(BOOL paused) {
    pthread_mutex_lock(&gDeliveryLock);
    gFeedPaused = paused;
    pthread_mutex_unlock(&gDeliveryLock);
}

void GC_SetMicDeliveryMode(NSString *mode) {
    pthread_mutex_lock(&gDeliveryLock);
    if ([mode isEqualToString:@"notReady"]) {
        gMicDeliveryMode = 1;
    } else if ([mode isEqualToString:@"withheld"]) {
        gMicDeliveryMode = 2;
    } else {
        gMicDeliveryMode = 0;
    }
    pthread_mutex_unlock(&gDeliveryLock);
}
