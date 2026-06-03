#import "FrameSocket.h"
#import "GeistShimCore.h"
#import "ShimLog.h"
#import "SocketIO.h"
#import "Wire.h"

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AudioToolbox/AudioToolbox.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <pthread.h>
#import <unistd.h>
#import <string.h>
#import <errno.h>

static int gClientFD = -1;
static pthread_mutex_t gClientLock = PTHREAD_MUTEX_INITIALIZER;

static const char *FrameSocketPath(void) {
    const char *env = getenv("GEISTCAST_HOST_SOCKET");
    return env;
}

static int Connect(void) {
    const char *path = FrameSocketPath();
    if (!path || !path[0]) {
        GC_ERR("GEISTCAST_HOST_SOCKET not set");
        return -1;
    }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        GC_ERR("connect(%{public}s) failed: errno=%d", path, errno);
        close(fd);
        return -1;
    }
    GC_LOG("connected to host socket %{public}s (fd=%d)", path, fd);
    return fd;
}

int GC_OpenFrameSocket(void) {
    pthread_mutex_lock(&gClientLock);
    if (gClientFD < 0) gClientFD = Connect();
    int fd = gClientFD;
    pthread_mutex_unlock(&gClientLock);
    return fd;
}

void GC_DropFrameClient(void) {
    pthread_mutex_lock(&gClientLock);
    if (gClientFD >= 0) {
        // shutdown() before close() forces a blocked read() in another
        // thread to return; close() alone is unreliable for that.
        shutdown(gClientFD, SHUT_RDWR);
        close(gClientFD);
        gClientFD = -1;
    }
    pthread_mutex_unlock(&gClientLock);
}

static NSDictionary *PixelBufferAttrs(OSType formatType) {
    return @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferPixelFormatTypeKey: @(formatType),
    };
}

static CVPixelBufferRef BuildBGRAPixelBuffer(const void *srcBytes, size_t srcLen,
                                             size_t width, size_t height,
                                             size_t bytesPerRow) {
    size_t expected;
    if (__builtin_mul_overflow(bytesPerRow, height, &expected) || expected != srcLen) {
        GC_ERR("BGRA payload size mismatch: %zu vs %zu", srcLen, expected);
        return NULL;
    }
    CVPixelBufferRef pb = NULL;
    CVReturn err = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)PixelBufferAttrs(kCVPixelFormatType_32BGRA), &pb);
    if (err != kCVReturnSuccess || !pb) {
        GC_ERR("CVPixelBufferCreate(BGRA) failed: %d", err);
        return NULL;
    }
    CVPixelBufferLockBaseAddress(pb, 0);
    void *dst = CVPixelBufferGetBaseAddress(pb);
    size_t dstStride = CVPixelBufferGetBytesPerRow(pb);
    if (dstStride == bytesPerRow) {
        memcpy(dst, srcBytes, srcLen);
    } else {
        const uint8_t *s = (const uint8_t *)srcBytes;
        uint8_t *d = (uint8_t *)dst;
        size_t copy = bytesPerRow < dstStride ? bytesPerRow : dstStride;
        for (size_t row = 0; row < height; row++) {
            memcpy(d + row * dstStride, s + row * bytesPerRow, copy);
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

static CVPixelBufferRef BuildNV12PixelBuffer(const void *srcBytes, size_t srcLen,
                                             size_t width, size_t height,
                                             size_t bytesPerRowPlane0,
                                             size_t bytesPerRowPlane1) {
    size_t ySize, uvSize;
    if (__builtin_mul_overflow(bytesPerRowPlane0, height, &ySize)) return NULL;
    if (__builtin_mul_overflow(bytesPerRowPlane1, height / 2, &uvSize)) return NULL;
    if (ySize + uvSize != srcLen) {
        GC_ERR("NV12 payload size mismatch: %zu vs %zu", srcLen, ySize + uvSize);
        return NULL;
    }
    CVPixelBufferRef pb = NULL;
    CVReturn err = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        (__bridge CFDictionaryRef)PixelBufferAttrs(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        &pb);
    if (err != kCVReturnSuccess || !pb) {
        GC_ERR("CVPixelBufferCreate(NV12) failed: %d", err);
        return NULL;
    }
    CVPixelBufferLockBaseAddress(pb, 0);
    const uint8_t *src = (const uint8_t *)srcBytes;
    uint8_t *yDst = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    uint8_t *uvDst = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    size_t yDstStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    size_t uvDstStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    size_t yCopy = bytesPerRowPlane0 < yDstStride ? bytesPerRowPlane0 : yDstStride;
    size_t uvCopy = bytesPerRowPlane1 < uvDstStride ? bytesPerRowPlane1 : uvDstStride;
    for (size_t row = 0; row < height; row++) {
        memcpy(yDst + row * yDstStride, src + row * bytesPerRowPlane0, yCopy);
    }
    const uint8_t *uvSrc = src + ySize;
    for (size_t row = 0; row < height / 2; row++) {
        memcpy(uvDst + row * uvDstStride, uvSrc + row * bytesPerRowPlane1, uvCopy);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

static CMSampleBufferRef BuildVideoSampleBuffer(const geistcast_frame_header_t *hdr,
                                                const void *payload) {
    CVPixelBufferRef pb = NULL;
    switch (hdr->pixelFormatFourCC) {
        case GEISTCAST_PIXFMT_BGRA32:
            pb = BuildBGRAPixelBuffer(payload, hdr->payloadSize,
                                       hdr->width, hdr->height, hdr->bytesPerRowPlane0);
            break;
        case GEISTCAST_PIXFMT_NV12_VIDEO:
            pb = BuildNV12PixelBuffer(payload, hdr->payloadSize,
                                       hdr->width, hdr->height,
                                       hdr->bytesPerRowPlane0, hdr->bytesPerRowPlane1);
            break;
        default:
            GC_ERR("unsupported pixel format: 0x%08x", hdr->pixelFormatFourCC);
            return NULL;
    }
    if (!pb) return NULL;

    CMTime hostTime = CMClockGetTime(CMClockGetHostTimeClock());
    CMSampleTimingInfo timing = {0};
    timing.presentationTimeStamp = hostTime;
    timing.duration = CMTimeMake(1, 30);
    timing.decodeTimeStamp = kCMTimeInvalid;

    CMVideoFormatDescriptionRef fmtDesc = NULL;
    OSStatus s = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fmtDesc);
    if (s != noErr || !fmtDesc) { CVPixelBufferRelease(pb); return NULL; }

    CMSampleBufferRef out = NULL;
    s = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pb, true, NULL, NULL,
                                           fmtDesc, &timing, &out);
    CFRelease(fmtDesc);
    CVPixelBufferRelease(pb);
    if (s != noErr) { GC_ERR("CMSampleBufferCreateForImageBuffer failed: %d", (int)s); return NULL; }

    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(out, true);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef d = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(d, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    }
    return out;
}

static CMSampleBufferRef BuildAudioSampleBuffer(const geistcast_frame_header_t *hdr,
                                                const void *payload,
                                                BOOL forceUnready) {
    AudioStreamBasicDescription asbd = {0};
    asbd.mSampleRate = (Float64)hdr->audioSampleRate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mChannelsPerFrame = hdr->audioChannelCount;
    asbd.mFramesPerPacket = 1;

    UInt32 bytesPerSample = 0;
    switch (hdr->audioSampleFormat) {
        case GEISTCAST_AUDIO_PCM_INT16:
            bytesPerSample = 2;
            asbd.mBitsPerChannel = 16;
            asbd.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
            break;
        case GEISTCAST_AUDIO_PCM_FLOAT32:
            bytesPerSample = 4;
            asbd.mBitsPerChannel = 32;
            asbd.mFormatFlags = kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked;
            break;
        default:
            GC_ERR("unsupported audio sample format: %u", hdr->audioSampleFormat);
            return NULL;
    }

    BOOL interleaved = hdr->audioInterleaved != 0;
    if (interleaved) {
        asbd.mBytesPerFrame = bytesPerSample * hdr->audioChannelCount;
        asbd.mBytesPerPacket = asbd.mBytesPerFrame;
    } else {
        asbd.mBytesPerFrame = bytesPerSample;
        asbd.mBytesPerPacket = bytesPerSample;
        asbd.mFormatFlags |= kAudioFormatFlagIsNonInterleaved;
    }

    CMAudioFormatDescriptionRef fmtDesc = NULL;
    OSStatus s = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd,
                                                0, NULL, 0, NULL, NULL, &fmtDesc);
    if (s != noErr || !fmtDesc) {
        GC_ERR("CMAudioFormatDescriptionCreate failed: %d", (int)s);
        return NULL;
    }

    void *dataCopy = malloc(hdr->payloadSize);
    if (!dataCopy) { CFRelease(fmtDesc); return NULL; }
    memcpy(dataCopy, payload, hdr->payloadSize);

    CMBlockBufferRef blockBuffer = NULL;
    s = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault, dataCopy, hdr->payloadSize,
        kCFAllocatorMalloc, NULL, 0, hdr->payloadSize,
        0, &blockBuffer);
    if (s != noErr || !blockBuffer) {
        free(dataCopy);
        CFRelease(fmtDesc);
        GC_ERR("CMBlockBufferCreateWithMemoryBlock failed: %d", (int)s);
        return NULL;
    }

    CMTime pts = CMClockGetTime(CMClockGetHostTimeClock());

    Boolean dataReady = forceUnready ? false : true;
    CMSampleBufferRef out = NULL;
    s = CMSampleBufferCreate(
        kCFAllocatorDefault, blockBuffer, dataReady, NULL, NULL,
        fmtDesc, (CMItemCount)hdr->audioSampleCount,
        1, &(CMSampleTimingInfo){
            .duration = CMTimeMake(1, (int32_t)hdr->audioSampleRate),
            .presentationTimeStamp = pts,
            .decodeTimeStamp = kCMTimeInvalid,
        },
        0, NULL, &out);
    CFRelease(blockBuffer);
    CFRelease(fmtDesc);
    if (s != noErr) {
        GC_ERR("CMSampleBufferCreate(audio) failed: %d", (int)s);
        return NULL;
    }

    if (!forceUnready) {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(out, true);
        if (attachments && CFArrayGetCount(attachments) > 0) {
            CFMutableDictionaryRef d = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
            CFDictionarySetValue(d, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        }
    }
    return out;
}

GCDeliveredSample GC_ReadNextSample(int fd, BOOL micUnreadyOverride) {
    GCDeliveredSample empty = { .sampleBuffer = NULL, .type = 0 };

    geistcast_frame_header_t hdr;
    if (GC_ReadAll(fd, &hdr, sizeof(hdr)) < 0) {
        GC_DropFrameClient();
        return empty;
    }
    if (hdr.magic != GEISTCAST_WIRE_MAGIC) {
        GC_ERR("magic mismatch: %u", hdr.magic);
        GC_DropFrameClient();
        return empty;
    }
    if (hdr.payloadSize > 64u * 1024u * 1024u) {
        GC_ERR("payloadSize out of range: %u", hdr.payloadSize);
        GC_DropFrameClient();
        return empty;
    }
    void *payload = NULL;
    if (hdr.payloadSize > 0) {
        payload = malloc(hdr.payloadSize);
        if (!payload) return empty;
        if (GC_ReadAll(fd, payload, hdr.payloadSize) < 0) {
            free(payload);
            GC_DropFrameClient();
            return empty;
        }
    }

    GCDeliveredSample result = empty;
    switch (hdr.streamType) {
        case GEISTCAST_STREAM_VIDEO:
            result.sampleBuffer = BuildVideoSampleBuffer(&hdr, payload);
            result.type = GCFeedSampleBufferTypeVideo;
            break;
        case GEISTCAST_STREAM_AUDIO_MIC: {
            BOOL forceUnready = micUnreadyOverride;
            result.sampleBuffer = BuildAudioSampleBuffer(&hdr, payload, forceUnready);
            result.type = GCFeedSampleBufferTypeAudioMic;
            break;
        }
        case GEISTCAST_STREAM_AUDIO_APP:
            result.sampleBuffer = BuildAudioSampleBuffer(&hdr, payload, NO);
            result.type = GCFeedSampleBufferTypeAudioApp;
            break;
        default:
            GC_ERR("unsupported stream type: 0x%08x", hdr.streamType);
            break;
    }
    free(payload);
    return result;
}
