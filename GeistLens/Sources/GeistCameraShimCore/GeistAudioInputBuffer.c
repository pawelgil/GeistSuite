#include "GeistAudioInputBuffer.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>

struct GeistAudioInputBuffer {
    AudioStreamBasicDescription format;
    size_t capacity;
    float *samples;
    _Atomic size_t write;
    _Atomic size_t read;
    _Atomic size_t discardThrough;
    double sourceRate;
    double phase;
    float previous[2];
    bool hasPrevious;
};

GeistAudioInputBuffer *geistAudioInputBufferCreate(AudioStreamBasicDescription format, size_t capacity) {
    bool floating = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    bool planar = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    unsigned bytes = floating ? 4 : 2;
    if (format.mFormatID != kAudioFormatLinearPCM || !isfinite(format.mSampleRate) ||
        format.mSampleRate < 8000 || format.mSampleRate > 192000 ||
        format.mChannelsPerFrame < 1 || format.mChannelsPerFrame > 2 ||
        format.mBitsPerChannel != bytes * 8 ||
        !(format.mFormatFlags & kAudioFormatFlagIsPacked) ||
        (!floating && !(format.mFormatFlags & kAudioFormatFlagIsSignedInteger)) ||
        (format.mFormatFlags & kAudioFormatFlagIsBigEndian) ||
        format.mBytesPerFrame != bytes * (planar ? 1 : format.mChannelsPerFrame) ||
        capacity == 0 || capacity > 192000) return NULL;
    GeistAudioInputBuffer *buffer = calloc(1, sizeof(*buffer));
    if (!buffer) return NULL;
    buffer->samples = calloc(capacity * format.mChannelsPerFrame, sizeof(float));
    if (!buffer->samples) { free(buffer); return NULL; }
    buffer->format = format;
    buffer->capacity = capacity;
    return buffer;
}

void geistAudioInputBufferDestroy(GeistAudioInputBuffer *buffer) {
    if (!buffer) return;
    free(buffer->samples);
    free(buffer);
}

// Only the consumer can reclaim storage while rendering may still read it.
void geistAudioInputBufferRequestDiscard(GeistAudioInputBuffer *buffer) {
    if (!buffer) return;
    atomic_store_explicit(&buffer->discardThrough, atomic_load(&buffer->write), memory_order_release);
    buffer->hasPrevious = false;
    buffer->phase = 0;
}

// Both producer and render callbacks must be quiescent during reset.
void geistAudioInputBufferReset(GeistAudioInputBuffer *buffer) {
    if (!buffer) return;
    atomic_store(&buffer->read, 0);
    atomic_store(&buffer->write, 0);
    atomic_store(&buffer->discardThrough, 0);
    buffer->hasPrevious = false;
    buffer->phase = 0;
}

// One socket reader publishes samples; one AudioUnit render thread consumes them.
bool geistAudioInputBufferAppend(GeistAudioInputBuffer *buffer, const float *samples,
                                size_t frames, unsigned channels, double sampleRate) {
    if (!buffer || !samples || channels < 1 || channels > 2 ||
        !isfinite(sampleRate) || sampleRate < 8000 || sampleRate > 192000) return false;
    if (buffer->sourceRate != sampleRate) {
        buffer->sourceRate = sampleRate;
        buffer->hasPrevious = false;
        buffer->phase = 0;
    }
    unsigned outputChannels = buffer->format.mChannelsPerFrame;
    double step = sampleRate / buffer->format.mSampleRate;
    size_t write = atomic_load_explicit(&buffer->write, memory_order_relaxed);
    bool admitted = true;
    for (size_t frame = 0; frame < frames; frame++) {
        float current[2] = { samples[frame * channels], samples[frame * channels + channels - 1] };
        if (outputChannels == 1) current[0] = (current[0] + current[1]) * 0.5f;
        if (!buffer->hasPrevious) {
            buffer->previous[0] = current[0]; buffer->previous[1] = current[1];
            buffer->hasPrevious = true;
            continue;
        }
        while (buffer->phase < 1) {
            size_t read = atomic_load_explicit(&buffer->read, memory_order_acquire);
            if (write - read < buffer->capacity) {
                for (unsigned ch = 0; ch < outputChannels; ch++) {
                    float value = buffer->previous[ch] + (current[ch] - buffer->previous[ch]) * buffer->phase;
                    buffer->samples[(write % buffer->capacity) * outputChannels + ch] = isfinite(value) ? value : 0;
                }
                write++;
                atomic_store_explicit(&buffer->write, write, memory_order_release);
            } else { admitted = false; }
            buffer->phase += step;
        }
        buffer->phase -= 1;
        buffer->previous[0] = current[0]; buffer->previous[1] = current[1];
    }
    return admitted;
}

OSStatus geistAudioInputBufferRender(GeistAudioInputBuffer *buffer, AudioBufferList *output,
                                    UInt32 frames, AudioUnitRenderActionFlags *flags) {
    if (!buffer || !output) return kAudio_ParamError;
    unsigned channels = buffer->format.mChannelsPerFrame;
    bool planar = (buffer->format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    bool floating = (buffer->format.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    unsigned buffers = planar ? channels : 1;
    if (output->mNumberBuffers != buffers || frames > UINT32_MAX / buffer->format.mBytesPerFrame)
        return kAudio_ParamError;
    UInt32 size = frames * buffer->format.mBytesPerFrame;
    for (unsigned i = 0; i < buffers; i++) {
        if (!output->mBuffers[i].mData || output->mBuffers[i].mDataByteSize < size) return kAudio_ParamError;
    }
    size_t read = atomic_load_explicit(&buffer->read, memory_order_relaxed);
    size_t discard = atomic_load_explicit(&buffer->discardThrough, memory_order_acquire);
    if (discard > read) read = discard;
    size_t write = atomic_load_explicit(&buffer->write, memory_order_acquire);
    size_t available = write - read;
    bool silent = true;
    for (UInt32 frame = 0; frame < frames; frame++) {
        for (unsigned ch = 0; ch < channels; ch++) {
            float value = frame < available ? buffer->samples[((read + frame) % buffer->capacity) * channels + ch] : 0;
            unsigned index = planar ? frame : frame * channels + ch;
            void *data = output->mBuffers[planar ? ch : 0].mData;
            if (floating) ((float *)data)[index] = value;
            else ((int16_t *)data)[index] = (int16_t)lrintf(fmaxf(-32768, fminf(32767, value * 32768)));
            if (value != 0) silent = false;
        }
    }
    atomic_store_explicit(&buffer->read, read + (frames < available ? frames : available), memory_order_release);
    for (unsigned i = 0; i < buffers; i++) output->mBuffers[i].mDataByteSize = size;
    if (flags) {
        if (silent) *flags |= kAudioUnitRenderAction_OutputIsSilence;
        else *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
    }
    return noErr;
}
