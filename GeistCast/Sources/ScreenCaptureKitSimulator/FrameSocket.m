#import "FrameSocket.h"
#import "GeistScreenCaptureWire.h"
#import "SocketIO.h"

#import <AudioToolbox/AudioToolbox.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <ctype.h>
#import <stdio.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

static bool GSCKSocketPath(char path[static 104]) {
    const char *simulator = getenv("SIMULATOR_UDID");
    if (!simulator || !simulator[0]) return false;
    int length = snprintf(path, 104, "/tmp/geistsck-%s.sock", simulator);
    if (length < 0 || length >= 104) return false;
    for (int index = 0; index < length; index++) {
        path[index] = (char)tolower(path[index]);
    }
    return true;
}

bool GSCKIsAvailable(void) {
    char path[104];
    return GSCKSocketPath(path) && access(path, F_OK) == 0;
}

static int WriteAll(int fd, const void *bytes, size_t length) {
    size_t written = 0;
    while (written < length) {
        ssize_t count = write(fd, (const uint8_t *)bytes + written, length - written);
        if (count <= 0) return -1;
        written += (size_t)count;
    }
    return 0;
}

int GSCKConnect(uint32_t outputs, int32_t *status) {
    char path[104];
    if (!GSCKSocketPath(path)) return -1;

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));

    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof(address.sun_path)) {
        close(fd);
        return -1;
    }
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd);
        return -1;
    }

    geist_sck_start_request_t request = {
        .magic = GEIST_SCK_WIRE_MAGIC,
        .version = GEIST_SCK_WIRE_VERSION,
        .outputs = outputs,
    };
    geist_sck_start_response_t response = {0};
    if (WriteAll(fd, &request, sizeof(request)) != 0 ||
        GC_ReadAll(fd, &response, sizeof(response)) < 0 ||
        response.magic != GEIST_SCK_WIRE_MAGIC) {
        close(fd);
        return -1;
    }
    if (status) *status = response.status;
    if (response.status != GEIST_SCK_STATUS_OK) {
        close(fd);
        return -1;
    }
    return fd;
}

void GSCKClose(int fd) {
    if (fd < 0) return;
    shutdown(fd, SHUT_RDWR);
    close(fd);
}

void GSCKShutdown(int fd) {
    if (fd >= 0) shutdown(fd, SHUT_RDWR);
}

static NSDictionary *PixelBufferAttributes(OSType format) {
    return @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferPixelFormatTypeKey: @(format),
    };
}

static CGFloat ActiveScreenScale(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            return ((UIWindowScene *)scene).screen.scale;
        }
    }
    return 1;
}

static CVPixelBufferRef BuildBGRAPixelBuffer(const void *source,
                                             const geist_sck_frame_header_t *header) {
    size_t expected = (size_t)header->bytesPerRowPlane0 * header->height;
    if (expected != header->payloadSize) return NULL;

    CVPixelBufferRef buffer = NULL;
    CVReturn result = CVPixelBufferCreate(
        kCFAllocatorDefault,
        header->width,
        header->height,
        kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)PixelBufferAttributes(kCVPixelFormatType_32BGRA),
        &buffer
    );
    if (result != kCVReturnSuccess || !buffer) return NULL;

    CVPixelBufferLockBaseAddress(buffer, 0);
    uint8_t *destination = CVPixelBufferGetBaseAddress(buffer);
    size_t destinationStride = CVPixelBufferGetBytesPerRow(buffer);
    size_t copyLength = MIN(destinationStride, header->bytesPerRowPlane0);
    for (size_t row = 0; row < header->height; row++) {
        memcpy(destination + row * destinationStride,
               (const uint8_t *)source + row * header->bytesPerRowPlane0,
               copyLength);
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return buffer;
}

static CVPixelBufferRef BuildNV12PixelBuffer(const void *source,
                                             const geist_sck_frame_header_t *header) {
    size_t ySize = (size_t)header->bytesPerRowPlane0 * header->height;
    size_t uvSize = (size_t)header->bytesPerRowPlane1 * (header->height / 2);
    if (ySize + uvSize != header->payloadSize) return NULL;

    CVPixelBufferRef buffer = NULL;
    CVReturn result = CVPixelBufferCreate(
        kCFAllocatorDefault,
        header->width,
        header->height,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        (__bridge CFDictionaryRef)PixelBufferAttributes(
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ),
        &buffer
    );
    if (result != kCVReturnSuccess || !buffer) return NULL;

    CVPixelBufferLockBaseAddress(buffer, 0);
    for (size_t plane = 0; plane < 2; plane++) {
        size_t sourceStride = plane == 0
            ? header->bytesPerRowPlane0
            : header->bytesPerRowPlane1;
        size_t rows = plane == 0 ? header->height : header->height / 2;
        size_t sourceOffset = plane == 0 ? 0 : ySize;
        uint8_t *destination = CVPixelBufferGetBaseAddressOfPlane(buffer, plane);
        size_t destinationStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane);
        size_t copyLength = MIN(destinationStride, sourceStride);
        for (size_t row = 0; row < rows; row++) {
            memcpy(destination + row * destinationStride,
                   (const uint8_t *)source + sourceOffset + row * sourceStride,
                   copyLength);
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return buffer;
}

static CMSampleBufferRef BuildVideoSampleBuffer(const void *payload,
                                                const geist_sck_frame_header_t *header) {
    CVPixelBufferRef pixelBuffer = NULL;
    if (header->pixelFormatFourCC == GEIST_SCK_PIXFMT_BGRA32) {
        pixelBuffer = BuildBGRAPixelBuffer(payload, header);
    } else if (header->pixelFormatFourCC == GEIST_SCK_PIXFMT_NV12_VIDEO) {
        pixelBuffer = BuildNV12PixelBuffer(payload, header);
    }
    if (!pixelBuffer) return NULL;

    CMVideoFormatDescriptionRef format = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(
            kCFAllocatorDefault, pixelBuffer, &format
        ) != noErr || !format) {
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }

    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, 60),
        .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sample = NULL;
    OSStatus result = CMSampleBufferCreateForImageBuffer(
        kCFAllocatorDefault, pixelBuffer, true, NULL, NULL, format, &timing, &sample
    );
    CFRelease(format);
    CVPixelBufferRelease(pixelBuffer);
    if (result != noErr || !sample) return NULL;

    CMSetAttachment(sample, (__bridge CFStringRef)SCStreamFrameInfoStatus,
                    (__bridge CFTypeRef)@(SCFrameStatusComplete),
                    kCMAttachmentMode_ShouldPropagate);
    CGFloat scale = ActiveScreenScale();
    CMSetAttachment(sample, (__bridge CFStringRef)SCStreamFrameInfoContentRect,
                    (__bridge CFTypeRef)[NSValue valueWithCGRect:CGRectMake(
                        0, 0, header->width / scale, header->height / scale
                    )], kCMAttachmentMode_ShouldPropagate);
    CMSetAttachment(sample, (__bridge CFStringRef)SCStreamFrameInfoContentScale,
                    (__bridge CFTypeRef)@(scale),
                    kCMAttachmentMode_ShouldPropagate);
    CMSetAttachment(sample, (__bridge CFStringRef)SCStreamFrameInfoScaleFactor,
                    (__bridge CFTypeRef)@(scale),
                    kCMAttachmentMode_ShouldPropagate);
    return sample;
}

static CMSampleBufferRef BuildAudioSampleBuffer(const void *payload,
                                                const geist_sck_frame_header_t *header) {
    UInt32 bytesPerSample;
    AudioFormatFlags flags = kAudioFormatFlagIsPacked;
    if (header->audioSampleFormat == GEIST_SCK_AUDIO_PCM_FLOAT32) {
        bytesPerSample = 4;
        flags |= kAudioFormatFlagIsFloat;
    } else if (header->audioSampleFormat == GEIST_SCK_AUDIO_PCM_INT16) {
        bytesPerSample = 2;
        flags |= kAudioFormatFlagIsSignedInteger;
    } else {
        return NULL;
    }
    if (!header->audioInterleaved) flags |= kAudioFormatFlagIsNonInterleaved;

    AudioStreamBasicDescription description = {
        .mSampleRate = header->audioSampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = flags,
        .mBytesPerPacket = bytesPerSample * (header->audioInterleaved
            ? header->audioChannelCount : 1),
        .mFramesPerPacket = 1,
        .mBytesPerFrame = bytesPerSample * (header->audioInterleaved
            ? header->audioChannelCount : 1),
        .mChannelsPerFrame = header->audioChannelCount,
        .mBitsPerChannel = bytesPerSample * 8,
    };
    CMAudioFormatDescriptionRef format = NULL;
    if (CMAudioFormatDescriptionCreate(
            kCFAllocatorDefault, &description, 0, NULL, 0, NULL, NULL, &format
        ) != noErr || !format) return NULL;

    void *copy = malloc(header->payloadSize);
    if (!copy) {
        CFRelease(format);
        return NULL;
    }
    memcpy(copy, payload, header->payloadSize);
    CMBlockBufferRef block = NULL;
    OSStatus result = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault, copy, header->payloadSize, kCFAllocatorMalloc,
        NULL, 0, header->payloadSize, 0, &block
    );
    if (result != noErr || !block) {
        free(copy);
        CFRelease(format);
        return NULL;
    }

    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, (int32_t)header->audioSampleRate),
        .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sample = NULL;
    result = CMSampleBufferCreate(
        kCFAllocatorDefault, block, true, NULL, NULL, format,
        header->audioSampleCount, 1, &timing, 0, NULL, &sample
    );
    CFRelease(block);
    CFRelease(format);
    return result == noErr ? sample : NULL;
}

GSCKDeliveredSample GSCKReadNextSample(int fd) {
    GSCKDeliveredSample empty = { .sampleBuffer = NULL, .type = 0 };
    geist_sck_frame_header_t header;
    if (GC_ReadAll(fd, &header, sizeof(header)) < 0 ||
        header.magic != GEIST_SCK_WIRE_MAGIC ||
        header.payloadSize > 64u * 1024u * 1024u) return empty;

    void *payload = malloc(header.payloadSize);
    if (!payload) return empty;
    if (GC_ReadAll(fd, payload, header.payloadSize) < 0) {
        free(payload);
        return empty;
    }

    GSCKDeliveredSample sample = empty;
    sample.type = (SCStreamOutputType)header.streamType;
    if (header.streamType == GEIST_SCK_STREAM_SCREEN) {
        sample.sampleBuffer = BuildVideoSampleBuffer(payload, &header);
    } else if (header.streamType == GEIST_SCK_STREAM_MICROPHONE) {
        sample.sampleBuffer = BuildAudioSampleBuffer(payload, &header);
    }
    free(payload);
    return sample;
}
