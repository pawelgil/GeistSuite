#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

void audioInputEnable(void);
void audioInputConfigure(bool configured);
void audioInputDiscard(void);
bool audioInputIsActive(void);
void audioInputReceive(const void *bytes, size_t byteCount, uint32_t frames,
                       uint32_t channels, uint32_t sampleRate, uint32_t bits, uint32_t format);
