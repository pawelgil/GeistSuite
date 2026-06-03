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
static volatile atomic_bool gFeedPaused = ATOMIC_VAR_INIT(false);
static volatile atomic_bool gMicUnready = ATOMIC_VAR_INIT(false);
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
            BOOL micUnready = atomic_load(&gMicUnready);
            GCDeliveredSample delivered = GC_ReadNextSample(fd, micUnready);
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
            if (atomic_load(&gFeedPaused)) {
                CFRelease(delivered.sampleBuffer);
                continue;
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
        }
    }
    GC_LOG("feed thread exiting after %lld samples", gFrameCount);
    return NULL;
}

void GC_StartFeedThread(id broadcastHandler) {
    gBroadcastHandler = broadcastHandler;
    gFrameCount = 0;
    atomic_store(&gFeedPaused, false);
    atomic_store(&gMicUnready, false);
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
    atomic_store(&gFeedPaused, paused ? true : false);
}

void GC_SetMicAudioReadiness(BOOL ready) {
    atomic_store(&gMicUnready, ready ? false : true);
}
