#ifndef GEISTCAST_WIRE_H
#define GEISTCAST_WIRE_H

#include <stdint.h>

typedef struct {
    uint32_t magic;
    uint32_t streamType;
    uint32_t pixelFormatFourCC;
    uint32_t width;
    uint32_t height;
    uint32_t bytesPerRowPlane0;
    uint32_t bytesPerRowPlane1;
    uint32_t audioSampleRate;
    uint32_t audioChannelCount;
    uint32_t audioSampleFormat;
    uint32_t audioInterleaved;
    uint32_t audioSampleCount;
    uint32_t payloadSize;
} geistcast_frame_header_t;

#define GEISTCAST_STREAM_VIDEO     0x56u
#define GEISTCAST_STREAM_AUDIO_MIC 0x4Du
#define GEISTCAST_STREAM_AUDIO_APP 0x41u

#define GEISTCAST_PIXFMT_BGRA32     0x42475241u
#define GEISTCAST_PIXFMT_NV12_VIDEO 0x34323076u

#define GEISTCAST_AUDIO_PCM_INT16   0x01u
#define GEISTCAST_AUDIO_PCM_FLOAT32 0x02u

#endif
