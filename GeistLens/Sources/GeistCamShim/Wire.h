// Wire framing:
//   uint32_t length;   // bytes that follow (type + payload)
//   uint32_t type;     // GeistCamMsgType
//   ...payload...
//
// Host byte order — both sides are arm64 on Apple Silicon, no htonl dance.

#pragma once
#include <stdint.h>
#include "MediaSourceFeatures.h"

#define GEISTCAM_WIRE_VERSION 1
#define GEISTCAM_SLOT_COUNT 3

typedef enum {
    GEISTCAM_MSG_HELLO            = 1,  // feeder → shim
    GEISTCAM_MSG_HELLO_ACK        = 2,  // shim → feeder
    GEISTCAM_MSG_SLOT_ACTIVE      = 3,  // shim → feeder
    GEISTCAM_MSG_VIDEO_FRAME      = 4,  // feeder → shim
    GEISTCAM_MSG_AUDIO_FRAME      = 5,  // feeder → shim
    GEISTCAM_MSG_DEMAND_UPDATE    = 6,  // shim → feeder
    GEISTCAM_MSG_METADATA_RESULTS = 7,  // feeder → shim
    GEISTCAM_MSG_RECORDING_STATE  = 8,  // shim → feeder
    GEISTCAM_MSG_ACTIVE_FORMAT    = 9,  // shim → feeder
} GeistCamMsgType;

typedef enum {
    GEISTCAM_META_KIND_QR   = 0,
    GEISTCAM_META_KIND_FACE = 1,
} GeistCamMetaKind;

typedef enum {
    GEISTCAM_SLOT_BACK_CAMERA  = 0,
    GEISTCAM_SLOT_FRONT_CAMERA = 1,
    GEISTCAM_SLOT_MICROPHONE   = 2,
} GeistCamSlot;

// Audio slots reuse this struct but ignore width/height/pixel_format/fps —
// rate/channels travel in AUDIO_FRAME headers instead.
typedef struct {
    uint32_t kind;            // GeistCamSlot
    uint32_t width;
    uint32_t height;
    uint32_t pixel_format;    // kCVPixelFormatType_* (e.g. '420f' = 0x34323066)
    uint32_t fps_num;
    uint32_t fps_den;
    uint32_t features;        // MediaSourceFeatures bitset
    uint32_t reserved;
} GeistCamSlotInfo;

// Variable-length: header followed by `slot_count` SlotInfo entries on the
// wire. Slots absent from HELLO present as "no such device" to AVF apps.
typedef struct {
    uint32_t version;
    uint32_t slot_count;
    // GeistCamSlotInfo slots[slot_count] follows on the wire — declared here
    // would force a C99 flexible array member, which doesn't bridge to Swift.
} GeistCamHelloHeader;

typedef struct {
    uint32_t version;
    uint32_t initial_active[GEISTCAM_SLOT_COUNT];  // boolean per slot
} GeistCamHelloAckMsg;

typedef struct {
    uint32_t slot;
    uint32_t active;          // boolean
} GeistCamSlotActiveMsg;

typedef struct {
    uint32_t slot;
    uint32_t width;
    uint32_t height;
    uint32_t pixel_format;
    int64_t  pts_ns;
    int64_t  duration_ns;
    uint32_t bytes_len;
    uint32_t reserved;
    // followed by `bytes_len` bytes of pixel data in `pixel_format` layout
} GeistCamVideoFrameMsg;

typedef struct {
    uint32_t slot;
    uint32_t sample_count;
    uint32_t sample_rate;
    uint32_t channels;
    uint32_t format;          // kAudioFormat* (e.g. kAudioFormatLinearPCM)
    uint32_t bits_per_channel;
    int64_t  pts_ns;
    uint32_t bytes_len;
    uint32_t reserved;
    // followed by `bytes_len` bytes of audio data
} GeistCamAudioFrameMsg;

typedef struct {
    uint32_t slot;
    uint32_t wants_qr;        // boolean
    uint32_t wants_face;      // boolean
} GeistCamDemandUpdateMsg;

typedef struct {
    uint32_t active;          // boolean: 1 = recording active, 0 = idle
} GeistCamRecordingStateMsg;

typedef struct {
    uint32_t slot;            // GeistCamSlot
    uint32_t width;
    uint32_t height;
    uint32_t pixel_format;    // kCVPixelFormatType_*
} GeistCamActiveFormatMsg;

typedef struct {
    uint32_t kind;            // GeistCamMetaKind
    int32_t  face_id;         // -1 for non-face objects
    float    bounds_x;        // AVF normalized coords, top-left origin
    float    bounds_y;
    float    bounds_w;
    float    bounds_h;
    uint32_t string_len;      // UTF-8 bytes follow this header (QR payload)
    uint32_t reserved;
} GeistCamMetadataObjectHeader;

// object_count == 0 is a valid "nothing detected" signal — apps depend on it
// to clear metadata UI when a symbol leaves the frame.
typedef struct {
    uint32_t slot;
    uint32_t object_count;
    // followed by object_count × GeistCamMetadataObjectHeader, each with its
    // string_len bytes of UTF-8 trailing immediately after.
} GeistCamMetadataResultsMsg;
