#import "AudioInput.h"
#import "GeistAudioInputBuffer.h"
#import "Server.h"
#import <AudioToolbox/AudioToolbox.h>
#include <pthread.h>
#include <stdatomic.h>

typedef struct {
    _Atomic(AudioUnit) unit;
    GeistAudioInputBuffer *buffer;
    bool inputEnabled;
    bool started;
} AudioInputState;

static AudioInputState s_inputs[64];
static pthread_mutex_t s_mutex = PTHREAD_MUTEX_INITIALIZER;
static _Atomic bool s_enabled;
static _Atomic bool s_configured;

static AudioInputState *findInput(AudioUnit unit) {
    for (unsigned i = 0; i < 64; i++) {
        if (atomic_load_explicit(&s_inputs[i].unit, memory_order_acquire) == unit) return &s_inputs[i];
    }
    return NULL;
}

void audioInputEnable(void) { atomic_store(&s_enabled, true); }
void audioInputConfigure(bool configured) {
    audioInputDiscard();
    atomic_store(&s_configured, configured);
}

void audioInputDiscard(void) {
    pthread_mutex_lock(&s_mutex);
    for (unsigned i = 0; i < 64; i++) geistAudioInputBufferRequestDiscard(s_inputs[i].buffer);
    pthread_mutex_unlock(&s_mutex);
}

bool audioInputIsActive(void) {
    bool active = false;
    pthread_mutex_lock(&s_mutex);
    for (unsigned i = 0; i < 64; i++) {
        if (s_inputs[i].started && s_inputs[i].inputEnabled) { active = true; break; }
    }
    pthread_mutex_unlock(&s_mutex);
    return active;
}

void audioInputReceive(const void *bytes, size_t byteCount, uint32_t frames,
                       uint32_t channels, uint32_t sampleRate, uint32_t bits, uint32_t format) {
    if (bits != 32 || (format != 0 && format != kAudioFormatLinearPCM) ||
        channels < 1 || channels > 2 || byteCount != (uint64_t)frames * channels * sizeof(float)) return;
    pthread_mutex_lock(&s_mutex);
    for (unsigned i = 0; i < 64; i++) {
        AudioInputState *state = &s_inputs[i];
        if (state->started && state->inputEnabled && state->buffer)
            geistAudioInputBufferAppend(state->buffer, bytes, frames, channels, sampleRate);
    }
    pthread_mutex_unlock(&s_mutex);
}

static OSStatus inputInstanceNew(AudioComponent component, AudioComponentInstance *instance) {
    OSStatus status = AudioComponentInstanceNew(component, instance);
    if (status != noErr || !instance || !*instance || !atomic_load(&s_enabled)) return status;
    AudioComponentDescription description = {0};
    if (AudioComponentGetDescription(component, &description) != noErr ||
        description.componentType != kAudioUnitType_Output ||
        (description.componentSubType != kAudioUnitSubType_VoiceProcessingIO &&
         description.componentSubType != kAudioUnitSubType_RemoteIO)) return status;
    pthread_mutex_lock(&s_mutex);
    for (unsigned i = 0; i < 64; i++) {
        if (atomic_load(&s_inputs[i].unit)) continue;
        atomic_store_explicit(&s_inputs[i].unit, *instance, memory_order_release);
        pthread_mutex_unlock(&s_mutex);
        return status;
    }
    pthread_mutex_unlock(&s_mutex);
    AudioComponentInstanceDispose(*instance);
    *instance = NULL;
    return kAudio_MemFullError;
}

static OSStatus inputSetProperty(AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope,
                                 AudioUnitElement element, const void *data, UInt32 size) {
    OSStatus status = AudioUnitSetProperty(unit, property, scope, element, data, size);
    if (status != noErr || property != kAudioOutputUnitProperty_EnableIO ||
        scope != kAudioUnitScope_Input || element != 1 || size != sizeof(UInt32) || !data) return status;
    pthread_mutex_lock(&s_mutex);
    AudioInputState *state = findInput(unit);
    if (state) state->inputEnabled = *(const UInt32 *)data != 0;
    pthread_mutex_unlock(&s_mutex);
    serverRecomputeAllSlots();
    return status;
}

static OSStatus inputInitialize(AudioUnit unit) {
    OSStatus status = AudioUnitInitialize(unit);
    if (status != noErr) return status;
    AudioStreamBasicDescription format = {0};
    UInt32 size = sizeof(format);
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
                             1, &format, &size) != noErr) return status;
    pthread_mutex_lock(&s_mutex);
    AudioInputState *state = findInput(unit);
    if (state && !state->started) {
        geistAudioInputBufferDestroy(state->buffer);
        state->buffer = geistAudioInputBufferCreate(format, 16384);
    }
    pthread_mutex_unlock(&s_mutex);
    return status;
}

static OSStatus inputStart(AudioUnit unit) {
    pthread_mutex_lock(&s_mutex);
    AudioInputState *state = findInput(unit);
    if (state && !state->started) geistAudioInputBufferReset(state->buffer);
    pthread_mutex_unlock(&s_mutex);
    OSStatus status = AudioOutputUnitStart(unit);
    if (status != noErr) return status;
    pthread_mutex_lock(&s_mutex);
    state = findInput(unit);
    if (state) state->started = true;
    pthread_mutex_unlock(&s_mutex);
    serverRecomputeAllSlots();
    return status;
}

static OSStatus inputStop(AudioUnit unit) {
    OSStatus status = AudioOutputUnitStop(unit);
    if (status != noErr) return status;
    pthread_mutex_lock(&s_mutex);
    AudioInputState *state = findInput(unit);
    if (state) state->started = false;
    pthread_mutex_unlock(&s_mutex);
    serverRecomputeAllSlots();
    return status;
}

static OSStatus inputDispose(AudioComponentInstance unit) {
    OSStatus status = AudioComponentInstanceDispose(unit);
    if (status != noErr) return status;
    // Disposal quiesces callbacks; the mutex excludes the socket producer during reclamation.
    pthread_mutex_lock(&s_mutex);
    AudioInputState *state = findInput(unit);
    if (state) {
        atomic_store_explicit(&state->unit, NULL, memory_order_release);
        geistAudioInputBufferDestroy(state->buffer);
        state->buffer = NULL;
        state->started = false;
        state->inputEnabled = false;
    }
    pthread_mutex_unlock(&s_mutex);
    serverRecomputeAllSlots();
    return status;
}

static OSStatus inputRender(AudioUnit unit, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                            UInt32 bus, UInt32 frames, AudioBufferList *data) {
    OSStatus status = AudioUnitRender(unit, flags, time, bus, frames, data);
    if (status != noErr || bus != 1 || !atomic_load(&s_configured)) return status;
    AudioInputState *state = findInput(unit);
    if (!state) return status;
    if (!state->buffer) return kAudioUnitErr_FormatNotSupported;
    return geistAudioInputBufferRender(state->buffer, data, frames, flags);
}

#define INPUT_INTERPOSE(replacement, original) \
    __attribute__((used)) static const struct { const void *replace; const void *original; } \
    interpose_##original __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)&replacement, (const void *)&original \
    }

INPUT_INTERPOSE(inputInstanceNew, AudioComponentInstanceNew);
INPUT_INTERPOSE(inputDispose, AudioComponentInstanceDispose);
INPUT_INTERPOSE(inputSetProperty, AudioUnitSetProperty);
INPUT_INTERPOSE(inputInitialize, AudioUnitInitialize);
INPUT_INTERPOSE(inputStart, AudioOutputUnitStart);
INPUT_INTERPOSE(inputStop, AudioOutputUnitStop);
INPUT_INTERPOSE(inputRender, AudioUnitRender);
