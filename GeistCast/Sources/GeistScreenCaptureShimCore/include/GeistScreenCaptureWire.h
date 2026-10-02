#pragma once

#include <stdint.h>

#define GEIST_SCK_WIRE_MAGIC 0x4753434Bu
#define GEIST_SCK_WIRE_VERSION 1u

#define GEIST_SCK_OUTPUT_SCREEN     (1u << 0)
#define GEIST_SCK_OUTPUT_AUDIO      (1u << 1)
#define GEIST_SCK_OUTPUT_MICROPHONE (1u << 2)

#define GEIST_SCK_STATUS_OK              0
#define GEIST_SCK_STATUS_BUSY           -1
#define GEIST_SCK_STATUS_NOT_SUPPORTED  -2
#define GEIST_SCK_STATUS_INVALID_REQUEST -3
#define GEIST_SCK_STATUS_FAILED          -4

#define GEIST_SCK_STREAM_SCREEN     0u
#define GEIST_SCK_STREAM_AUDIO      1u
#define GEIST_SCK_STREAM_MICROPHONE 2u

#define GEIST_SCK_PIXFMT_BGRA32     0x42475241u
#define GEIST_SCK_PIXFMT_NV12_VIDEO 0x34323076u

#define GEIST_SCK_AUDIO_PCM_INT16   0x01u
#define GEIST_SCK_AUDIO_PCM_FLOAT32 0x02u

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t outputs;
} geist_sck_start_request_t;

typedef struct {
    uint32_t magic;
    int32_t status;
} geist_sck_start_response_t;

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
} geist_sck_frame_header_t;
