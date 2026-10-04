#include "FrameValidation.h"

bool GSCKValidateFrameHeader(const geist_sck_frame_header_t *header) {
    if (!header || header->timestampNanoseconds >= 1000000000 || header->magic != GEIST_SCK_WIRE_MAGIC ||
        header->payloadSize == 0 || header->payloadSize > 64u * 1024u * 1024u) return false;
    if (header->streamType == GEIST_SCK_STREAM_SCREEN) {
        if (!header->width || !header->height || header->width > 16384 || header->height > 16384) return false;
        uint64_t size = (uint64_t)header->bytesPerRowPlane0 * header->height;
        if (header->pixelFormatFourCC == GEIST_SCK_PIXFMT_BGRA32) {
            if (header->bytesPerRowPlane0 < (uint64_t)header->width * 4 || header->bytesPerRowPlane1) return false;
        } else if (header->pixelFormatFourCC == GEIST_SCK_PIXFMT_NV12_VIDEO) {
            if (header->width % 2 || header->height % 2 ||
                header->bytesPerRowPlane0 < header->width || header->bytesPerRowPlane1 < header->width) return false;
            size += (uint64_t)header->bytesPerRowPlane1 * (header->height / 2);
        } else {
            return false;
        }
        return size == header->payloadSize;
    }
    if (header->streamType != GEIST_SCK_STREAM_MICROPHONE ||
        !header->audioSampleRate || header->audioSampleRate > 192000 ||
        !header->audioChannelCount || header->audioChannelCount > 8 ||
        !header->audioSampleCount || header->audioInterleaved > 1) return false;
    uint32_t bytesPerSample;
    switch (header->audioSampleFormat) {
        case GEIST_SCK_AUDIO_PCM_FLOAT32: bytesPerSample = 4; break;
        case GEIST_SCK_AUDIO_PCM_INT16: bytesPerSample = 2; break;
        default: return false;
    }
    return (uint64_t)header->audioSampleCount * header->audioChannelCount * bytesPerSample == header->payloadSize;
}
