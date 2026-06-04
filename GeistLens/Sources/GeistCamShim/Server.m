#import "Server.h"
#import "ActiveFormat.h"
#import "Dispatch.h"
#import "Metadata.h"
#import "OutputBinding.h"
#import "PreviewLayer.h"
#import "Provenance.h"
#import "RecordingState.h"
#import "Source.h"
#import "Util.h"
#import "Wire.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudioTypes.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include <errno.h>
#include <pthread.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

static int s_listen_fd = -1;
static int s_conn_fd = -1;
static dispatch_queue_t s_writeQueue;
static volatile BOOL s_serverConfigured;
static volatile BOOL s_helloReceived;
static GeistCamSlotInfo s_slotInfos[GEISTCAM_SLOT_COUNT];
static BOOL           s_slotConfigured[GEISTCAM_SLOT_COUNT];
static volatile uint32_t s_slotActive[GEISTCAM_SLOT_COUNT];
static pthread_mutex_t s_connMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t s_helloMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  s_helloCond  = PTHREAD_COND_INITIALIZER;

static void *acceptThread(void *arg);
static void readLoop(int fd);
static void handleHello(uint32_t version, uint32_t slotCount, const uint8_t *slotsBytes);
static void handleVideoFrame(const GeistCamVideoFrameMsg *hdr, const uint8_t *bytes);
static void handleAudioFrame(const GeistCamAudioFrameMsg *hdr, const uint8_t *bytes);
static void sendHelloAck(void);
static BOOL readExact(int fd, void *buf, size_t n);
static CVPixelBufferRef buildPixelBufferFromBytes(uint32_t w, uint32_t h, uint32_t fmt,
                                                  const uint8_t *bytes, size_t bytesLen);

// Falls back to /tmp/geistcam/<UDID>/<bundleID>.sock so an auto-injecting
// launcher can set DYLD_INSERT_LIBRARIES once for the whole sim.
static NSString *resolveSocketPath(void) {
    const char *envPath = getenv("GEISTCAM_SOCKET");
    if (envPath && *envPath) return [NSString stringWithUTF8String:envPath];

    const char *udid = getenv("SIMULATOR_UDID");
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (!udid || !*udid || bundleID.length == 0) return nil;
    NSString *dir = [NSString stringWithFormat:@"/tmp/geistcam/%s", udid];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil error:NULL];
    return [NSString stringWithFormat:@"%@/%@.sock", dir, bundleID];
}

BOOL startServerIfConfigured(void) {
    NSString *resolved = resolveSocketPath();
    if (!resolved) return NO;
    const char *path = resolved.fileSystemRepresentation;

    unlink(path);

    s_listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (s_listen_fd < 0) {
        geistcam_warnf("server: socket() failed: %s", strerror(errno));
        return NO;
    }

    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

    if (bind(s_listen_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        geistcam_warnf("server: bind(%s) failed: %s", path, strerror(errno));
        close(s_listen_fd);
        s_listen_fd = -1;
        return NO;
    }
    if (listen(s_listen_fd, 1) < 0) {
        geistcam_warnf("server: listen() failed: %s", strerror(errno));
        close(s_listen_fd);
        s_listen_fd = -1;
        return NO;
    }

    s_writeQueue = dispatch_queue_create("geistcam.server.write", DISPATCH_QUEUE_SERIAL);
    s_serverConfigured = YES;

    pthread_t thread;
    pthread_create(&thread, NULL, acceptThread, NULL);
    pthread_detach(thread);

    geistcam_markerf("server: listening on %s", path);
    return YES;
}


void serverNotifySlotActive(GeistCamSlot slot, BOOL active) {
    if ((unsigned)slot >= GEISTCAM_SLOT_COUNT) return;
    uint32_t prev = s_slotActive[slot];
    uint32_t next = active ? 1u : 0u;
    s_slotActive[slot] = next;
    if (!s_helloReceived || prev == next) return;
    GeistCamSlotActiveMsg msg = { (uint32_t)slot, next };
    serverWriteMessage(GEISTCAM_MSG_SLOT_ACTIVE, &msg, sizeof(msg));
    geistcam_debugf("server: SLOT_ACTIVE slot=%u active=%u", (uint32_t)slot, next);
}

void serverRecomputeAllSlots(void) {
    if (!s_serverConfigured) return;
    for (int i = 0; i < simSourceCount() && i < GEISTCAM_SLOT_COUNT; i++) {
        GeistCamSource *src = simSourceAtIndex(i);
        if (!src) continue;
        BOOL active = isSourceActive(src);
        serverNotifySlotActive((GeistCamSlot)src->kind, active);
    }
}

static void *acceptThread(void *arg) {
    while (1) {
        int fd = accept(s_listen_fd, NULL, NULL);
        if (fd < 0) {
            if (errno == EINTR) continue;
            geistcam_warnf("server: accept() failed: %s", strerror(errno));
            break;
        }
        geistcam_markerf("server: accepted feeder (fd=%d)", fd);
        pthread_mutex_lock(&s_connMutex);
        if (s_conn_fd >= 0) close(s_conn_fd);
        s_conn_fd = fd;
        s_helloReceived = NO;
        pthread_mutex_unlock(&s_connMutex);

        readLoop(fd);

        pthread_mutex_lock(&s_connMutex);
        if (s_conn_fd == fd) s_conn_fd = -1;
        pthread_mutex_unlock(&s_connMutex);
        s_helloReceived = NO;
        close(fd);
        geistcam_markerf("server: feeder disconnected (fd=%d)", fd);
    }
    return NULL;
}

static BOOL readExact(int fd, void *buf, size_t n) {
    uint8_t *p = (uint8_t *)buf;
    while (n > 0) {
        ssize_t r = recv(fd, p, n, 0);
        if (r <= 0) {
            if (r < 0 && errno == EINTR) continue;
            return NO;
        }
        p += r;
        n -= (size_t)r;
    }
    return YES;
}

static void readLoop(int fd) {
    uint8_t *payloadBuf = NULL;
    size_t payloadCap = 0;

    while (1) {
        @autoreleasepool {
        uint32_t length = 0;
        if (!readExact(fd, &length, sizeof(length))) break;
        // Bound a runaway/malicious feeder; type word is 4 bytes minimum.
        if (length < sizeof(uint32_t) || length > 64 * 1024 * 1024) {
            geistcam_warnf("server: bad length %u, dropping connection", length);
            break;
        }
        if (length > payloadCap) {
            free(payloadBuf);
            payloadCap = length;
            payloadBuf = (uint8_t *)malloc(payloadCap);
            if (!payloadBuf) { payloadCap = 0; break; }
        }
        if (!readExact(fd, payloadBuf, length)) break;

        uint32_t type = 0;
        memcpy(&type, payloadBuf, sizeof(type));
        const uint8_t *payload = payloadBuf + sizeof(type);
        size_t payloadLen = length - sizeof(type);

        switch (type) {
            case GEISTCAM_MSG_HELLO: {
                if (payloadLen < 8) break;
                uint32_t version, slotCount;
                memcpy(&version,   payload,     sizeof(uint32_t));
                memcpy(&slotCount, payload + 4, sizeof(uint32_t));
                size_t need = 8 + (size_t)slotCount * sizeof(GeistCamSlotInfo);
                if (payloadLen < need) {
                    geistcam_warnf("server: HELLO truncated (got %zu, need %zu)",
                                      payloadLen, need);
                    break;
                }
                handleHello(version, slotCount, payload + 8);
                break;
            }
            case GEISTCAM_MSG_VIDEO_FRAME: {
                if (payloadLen < sizeof(GeistCamVideoFrameMsg)) break;
                GeistCamVideoFrameMsg hdr;
                memcpy(&hdr, payload, sizeof(hdr));
                if (sizeof(hdr) + hdr.bytes_len > payloadLen) {
                    geistcam_warnf("server: video bytes_len overflow");
                    break;
                }
                handleVideoFrame(&hdr, payload + sizeof(hdr));
                break;
            }
            case GEISTCAM_MSG_AUDIO_FRAME: {
                if (payloadLen < sizeof(GeistCamAudioFrameMsg)) break;
                GeistCamAudioFrameMsg hdr;
                memcpy(&hdr, payload, sizeof(hdr));
                if (sizeof(hdr) + hdr.bytes_len > payloadLen) {
                    geistcam_warnf("server: audio bytes_len overflow");
                    break;
                }
                handleAudioFrame(&hdr, payload + sizeof(hdr));
                break;
            }
            case GEISTCAM_MSG_METADATA_RESULTS: {
                metadataHandleResultsMessage(payload, payloadLen);
                break;
            }
            default:
                geistcam_warnf("server: unknown message type %u", type);
                break;
        }
        }
    }
    free(payloadBuf);
}

uint32_t serverGetSlotFeatures(GeistCamSlot slot) {
    if (slot >= GEISTCAM_SLOT_COUNT) return 0;
    if (!s_slotConfigured[slot]) return 0;
    return s_slotInfos[slot].features;
}

static void handleHello(uint32_t version, uint32_t slotCount, const uint8_t *slotsBytes) {
    if (version != GEISTCAM_WIRE_VERSION) {
        geistcam_warnf("server: hello version mismatch (got %u, want %u)",
                          version, GEISTCAM_WIRE_VERSION);
        return;
    }
    // Reset before applying — feeder may reconnect with a different shape.
    memset(s_slotInfos, 0, sizeof(s_slotInfos));
    memset(s_slotConfigured, 0, sizeof(s_slotConfigured));
    for (uint32_t i = 0; i < slotCount; i++) {
        GeistCamSlotInfo info;
        memcpy(&info, slotsBytes + i * sizeof(GeistCamSlotInfo), sizeof(GeistCamSlotInfo));
        if (info.kind >= GEISTCAM_SLOT_COUNT) {
            geistcam_warnf("server: HELLO entry %u has invalid kind=%u — skipped",
                              i, info.kind);
            continue;
        }
        s_slotInfos[info.kind] = info;
        s_slotConfigured[info.kind] = YES;
        geistcam_markerf("server: configured slot[%u] %ux%u fps=%u/%u pixfmt=0x%08x features=0x%08x",
                          info.kind, info.width, info.height,
                          info.fps_num, info.fps_den, info.pixel_format, info.features);
    }
    // Recompute under helloReceived=NO so SLOT_ACTIVE doesn't race ahead of
    // HELLO_ACK on the wire — the ack must arrive first.
    serverRecomputeAllSlots();
    pthread_mutex_lock(&s_helloMutex);
    s_helloReceived = YES;
    pthread_cond_broadcast(&s_helloCond);
    pthread_mutex_unlock(&s_helloMutex);
    sendHelloAck();
}

BOOL serverWaitForHello(double timeoutSec, GeistCamSlotInfo *outSlots, BOOL *outConfigured) {
    if (!outSlots || !outConfigured) return NO;
    if (!s_serverConfigured) return NO;
    pthread_mutex_lock(&s_helloMutex);
    if (!s_helloReceived) {
        struct timespec ts;
        struct timeval tv;
        gettimeofday(&tv, NULL);
        long whole = (long)timeoutSec;
        long nanos = (long)((timeoutSec - (double)whole) * 1e9);
        ts.tv_sec  = tv.tv_sec  + whole;
        ts.tv_nsec = (long)tv.tv_usec * 1000 + nanos;
        if (ts.tv_nsec >= 1000000000L) { ts.tv_sec += 1; ts.tv_nsec -= 1000000000L; }
        while (!s_helloReceived) {
            int rv = pthread_cond_timedwait(&s_helloCond, &s_helloMutex, &ts);
            if (rv == ETIMEDOUT) break;
        }
    }
    BOOL got = s_helloReceived;
    if (got) {
        memcpy(outSlots, s_slotInfos, sizeof(s_slotInfos));
        memcpy(outConfigured, s_slotConfigured, sizeof(s_slotConfigured));
    }
    pthread_mutex_unlock(&s_helloMutex);
    return got;
}

static void sendHelloAck(void) {
    GeistCamHelloAckMsg ack = {0};
    ack.version = GEISTCAM_WIRE_VERSION;
    for (int i = 0; i < GEISTCAM_SLOT_COUNT; i++) {
        ack.initial_active[i] = s_slotActive[i] ? 1u : 0u;
    }
    serverWriteMessage(GEISTCAM_MSG_HELLO_ACK, &ack, sizeof(ack));
    geistcam_markerf("server: sent HELLO_ACK (active=[%u,%u,%u])",
                      ack.initial_active[0], ack.initial_active[1], ack.initial_active[2]);
    // Pre-existing app subscribers won't re-fire setMetadataObjectTypes, so
    // a fresh feeder needs us to push current demand explicitly.
    metadataResyncForNewFeeder();
    recordingResyncForNewFeeder();
    activeFormatResyncForNewFeeder();
}

static CVPixelBufferRef buildPixelBufferFromBytes(uint32_t width, uint32_t height,
                                                  uint32_t pixelFormat,
                                                  const uint8_t *bytes, size_t bytesLen) {
    CVPixelBufferRef pb = NULL;
    NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    CVReturn rv = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                      pixelFormat, (__bridge CFDictionaryRef)attrs, &pb);
    if (rv != kCVReturnSuccess || !pb) {
        geistcam_warnf("server: CVPixelBufferCreate failed (%d)", (int)rv);
        return NULL;
    }
    CVPixelBufferLockBaseAddress(pb, 0);

    if (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
        pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        // Wire layout is contiguous (Y plane then interleaved CbCr); CVPixelBuffer
        // planes may have row padding so copy row-by-row.
        size_t ySize = (size_t)width * height;
        size_t cbcrSize = ySize / 2;
        if (bytesLen < ySize + cbcrSize) {
            geistcam_warnf("server: 420 bytes_len too small (%zu < %zu)",
                              bytesLen, ySize + cbcrSize);
            CVPixelBufferUnlockBaseAddress(pb, 0);
            CVPixelBufferRelease(pb);
            return NULL;
        }
        uint8_t *yPlane = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
        size_t yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
        for (uint32_t row = 0; row < height; row++) {
            memcpy(yPlane + row * yStride, bytes + row * width, width);
        }
        const uint8_t *cbcrSrc = bytes + ySize;
        uint8_t *cbcrPlane = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
        size_t cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
        for (uint32_t row = 0; row < height / 2; row++) {
            memcpy(cbcrPlane + row * cbcrStride, cbcrSrc + row * width, width);
        }
    } else if (pixelFormat == kCVPixelFormatType_32BGRA) {
        size_t expected = (size_t)width * height * 4;
        if (bytesLen < expected) {
            geistcam_warnf("server: BGRA bytes_len too small (%zu < %zu)", bytesLen, expected);
            CVPixelBufferUnlockBaseAddress(pb, 0);
            CVPixelBufferRelease(pb);
            return NULL;
        }
        uint8_t *base = CVPixelBufferGetBaseAddress(pb);
        size_t stride = CVPixelBufferGetBytesPerRow(pb);
        size_t srcStride = (size_t)width * 4;
        for (uint32_t row = 0; row < height; row++) {
            memcpy(base + row * stride, bytes + row * srcStride, srcStride);
        }
    } else {
        geistcam_warnf("server: unsupported pixel format 0x%08x", pixelFormat);
        CVPixelBufferUnlockBaseAddress(pb, 0);
        CVPixelBufferRelease(pb);
        return NULL;
    }

    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

static void handleVideoFrame(const GeistCamVideoFrameMsg *hdr, const uint8_t *bytes) {
    if (hdr->slot >= GEISTCAM_SLOT_COUNT) return;
    GeistCamSource *src = findSourceByKind((GeistCamSourceKind)hdr->slot);
    if (!src || src->kind == GeistCamSourceKind_Audio) return;

    static uint32_t s_loggedFirstFrame[GEISTCAM_SLOT_COUNT];
    if (!s_loggedFirstFrame[hdr->slot]) {
        s_loggedFirstFrame[hdr->slot] = 1;
        geistcam_markerf("server: first VIDEO_FRAME slot=%u %ux%u pixfmt=0x%08x bytes=%u",
                          hdr->slot, hdr->width, hdr->height, hdr->pixel_format, hdr->bytes_len);
    }
    static uint32_t s_lastW[GEISTCAM_SLOT_COUNT];
    static uint32_t s_lastH[GEISTCAM_SLOT_COUNT];
    static uint32_t s_lastFmt[GEISTCAM_SLOT_COUNT];
    if (s_lastW[hdr->slot] != hdr->width || s_lastH[hdr->slot] != hdr->height ||
        s_lastFmt[hdr->slot] != hdr->pixel_format) {
        s_lastW[hdr->slot] = hdr->width;
        s_lastH[hdr->slot] = hdr->height;
        s_lastFmt[hdr->slot] = hdr->pixel_format;
        geistcam_markerf("server: VIDEO_FRAME slot=%u format change → %ux%u pixfmt=0x%08x",
                          hdr->slot, hdr->width, hdr->height, hdr->pixel_format);
    }

    // Pixel format must match — shim transform doesn't convert formats.
    // Dimensions float free: producers emit native dims; the shim's transform
    // does orientation-aware center-crop+scale to activeFormat downstream.
    int32_t afW = 0, afH = 0; uint32_t afPF = 0;
    if (activeFormatGet((GeistCamSlot)hdr->slot, &afW, &afH, &afPF)) {
        if (afPF != hdr->pixel_format) {
            static uint64_t s_dropCount[GEISTCAM_SLOT_COUNT];
            if ((s_dropCount[hdr->slot]++ % 60) == 0) {
                geistcam_debugf("server: drop slot=%u pixfmt=0x%08x ≠ AF pixfmt=0x%08x (n=%llu)",
                                hdr->slot, hdr->pixel_format, afPF,
                                (unsigned long long)s_dropCount[hdr->slot]);
            }
            return;
        }
    }

    CVPixelBufferRef pb = buildPixelBufferFromBytes(hdr->width, hdr->height,
                                                    hdr->pixel_format, bytes, hdr->bytes_len);
    if (!pb) return;

    CMVideoFormatDescriptionRef fmt = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fmt);
    if (!fmt) { CVPixelBufferRelease(pb); return; }

    CMTime pts = CMTimeMake(hdr->pts_ns, 1000000000);
    CMTime duration = (hdr->duration_ns > 0)
        ? CMTimeMake(hdr->duration_ns, 1000000000)
        : kCMTimeInvalid;
    CMSampleTimingInfo timing = { duration, pts, kCMTimeInvalid };

    CMSampleBufferRef sb = NULL;
    OSStatus status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pb, true,
                                                         NULL, NULL, fmt, &timing, &sb);
    CFRelease(fmt);
    CVPixelBufferRelease(pb);
    if (status != noErr || !sb) {
        geistcam_warnf("server: CMSampleBufferCreate failed (%d)", (int)status);
        return;
    }

    tagSampleBufferProvenance(sb);

    deliverToBoundOutputs(src, sb, pts);
    deliverFrameToPreviewLayers(sb, src);
    CFRelease(sb);
}

static void handleAudioFrame(const GeistCamAudioFrameMsg *hdr, const uint8_t *bytes) {
    if (hdr->slot >= GEISTCAM_SLOT_COUNT) return;
    GeistCamSource *src = findSourceByKind((GeistCamSourceKind)hdr->slot);
    if (!src || src->kind != GeistCamSourceKind_Audio) return;

    static uint32_t s_loggedFirstAudio[GEISTCAM_SLOT_COUNT];
    if (!s_loggedFirstAudio[hdr->slot]) {
        s_loggedFirstAudio[hdr->slot] = 1;
        geistcam_markerf("server: first AUDIO_FRAME slot=%u %uHz ch=%u samples=%u bytes=%u",
                          hdr->slot, hdr->sample_rate, hdr->channels,
                          hdr->sample_count, hdr->bytes_len);
    }

    AudioStreamBasicDescription asbd = {0};
    asbd.mSampleRate = (Float64)hdr->sample_rate;
    asbd.mFormatID = hdr->format ?: kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    asbd.mFramesPerPacket = 1;
    asbd.mChannelsPerFrame = hdr->channels;
    asbd.mBitsPerChannel = hdr->bits_per_channel;
    asbd.mBytesPerFrame = (hdr->bits_per_channel / 8) * hdr->channels;
    asbd.mBytesPerPacket = asbd.mBytesPerFrame;

    CMAudioFormatDescriptionRef fmt = NULL;
    OSStatus s = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL, 0, NULL, NULL, &fmt);
    if (s != noErr || !fmt) {
        geistcam_warnf("server: CMAudioFormatDescriptionCreate failed (%d)", (int)s);
        return;
    }

    CMBlockBufferRef bb = NULL;
    s = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, hdr->bytes_len,
                                           kCFAllocatorDefault, NULL, 0, hdr->bytes_len,
                                           kCMBlockBufferAssureMemoryNowFlag, &bb);
    if (s != noErr || !bb) { CFRelease(fmt); return; }
    s = CMBlockBufferReplaceDataBytes(bytes, bb, 0, hdr->bytes_len);
    if (s != noErr) { CFRelease(bb); CFRelease(fmt); return; }

    CMTime pts = CMTimeMake(hdr->pts_ns, 1000000000);
    CMSampleBufferRef sb = NULL;
    s = CMAudioSampleBufferCreateReadyWithPacketDescriptions(kCFAllocatorDefault, bb, fmt,
                                                             hdr->sample_count, pts, NULL, &sb);
    CFRelease(bb);
    CFRelease(fmt);
    if (s != noErr || !sb) {
        geistcam_warnf("server: CMAudioSampleBufferCreateReady failed (%d)", (int)s);
        return;
    }

    tagSampleBufferProvenance(sb);

    deliverToBoundOutputs(src, sb, pts);
    CFRelease(sb);
}

void serverWriteMessage(GeistCamMsgType type, const void *payload, size_t payloadLen) {
    pthread_mutex_lock(&s_connMutex);
    int fd = s_conn_fd;
    pthread_mutex_unlock(&s_connMutex);
    if (fd < 0) return;

    NSMutableData *buf = [NSMutableData dataWithCapacity:8 + payloadLen];
    uint32_t length = (uint32_t)(sizeof(uint32_t) + payloadLen);
    uint32_t typeWord = (uint32_t)type;
    [buf appendBytes:&length length:sizeof(length)];
    [buf appendBytes:&typeWord length:sizeof(typeWord)];
    if (payload && payloadLen) [buf appendBytes:payload length:payloadLen];

    NSData *frozen = [buf copy];
    int fdCapture = fd;
    dispatch_async(s_writeQueue, ^{
        const uint8_t *p = (const uint8_t *)frozen.bytes;
        size_t n = frozen.length;
        while (n > 0) {
            ssize_t w = send(fdCapture, p, n, 0);
            if (w <= 0) {
                if (w < 0 && errno == EINTR) continue;
                return;
            }
            p += w;
            n -= (size_t)w;
        }
    });
}
