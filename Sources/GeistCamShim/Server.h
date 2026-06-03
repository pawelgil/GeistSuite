// Listens on $GEISTCAM_SOCKET if set, otherwise the conventional path
// derived in Server.m's resolveSocketPath. With no feeder ever connected,
// camera slots stay silent and AVF apps see "no such device".

#pragma once
#import <Foundation/Foundation.h>
#include "Wire.h"

BOOL startServerIfConfigured(void);

// Source.m blocks here at FigCaptureSourceCopySources so it only mints sources
// for slots the feeder declared in HELLO.
BOOL serverWaitForHello(double timeoutSec, GeistCamSlotInfo *outSlots, BOOL *outConfigured);

void serverNotifySlotActive(GeistCamSlot slot, BOOL active);
void serverRecomputeAllSlots(void);

// MediaSourceFeatures bitset for the given slot (0 if no HELLO yet).
uint32_t serverGetSlotFeatures(GeistCamSlot slot);

// No-op if no feeder is connected. Thread-safe (writes serialize internally).
void serverWriteMessage(GeistCamMsgType type, const void *payload, size_t payloadLen);
