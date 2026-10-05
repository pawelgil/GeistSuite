#pragma once
#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stddef.h>

typedef struct GeistAudioInputBuffer GeistAudioInputBuffer;

GeistAudioInputBuffer *geistAudioInputBufferCreate(AudioStreamBasicDescription format, size_t capacity);
void geistAudioInputBufferDestroy(GeistAudioInputBuffer *buffer);
void geistAudioInputBufferRequestDiscard(GeistAudioInputBuffer *buffer);
void geistAudioInputBufferReset(GeistAudioInputBuffer *buffer);
bool geistAudioInputBufferAppend(GeistAudioInputBuffer *buffer, const float *samples,
                                size_t frames, unsigned channels, double sampleRate);
OSStatus geistAudioInputBufferRender(GeistAudioInputBuffer *buffer, AudioBufferList *output,
                                    UInt32 frames, AudioUnitRenderActionFlags *flags);
