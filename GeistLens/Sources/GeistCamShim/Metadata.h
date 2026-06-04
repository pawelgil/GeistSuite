// AVCaptureMetadataOutput emulation. Detection runs on the host (see
// GeistCam/Sources/GeistCam/Detection/) — in-simulator Vision/CIDetector
// is CPU-emulated and burns ~50% of one core for QR + face at 4fps.

#pragma once
#include <stddef.h>
#include <stdint.h>
#import <CoreMedia/CoreMedia.h>
#import "Source.h"

void installMetadataSwizzles(void);

void metadataDispatchVideoFrame(CMSampleBufferRef sb, GeistCamSource *src);

// Recompute per-slot demand and publish a DEMAND_UPDATE for any slot that
// changed. Cheap when nothing changed — call freely from binding swizzles.
void metadataInvalidateDemand(void);

// `payload` is the message body after the (length, type) framing header.
void metadataHandleResultsMessage(const uint8_t *payload, size_t payloadLen);

// On a fresh feeder connection: drop stale cached results and re-publish
// current demand so the new feeder starts detection without waiting for the
// next bindings change.
void metadataResyncForNewFeeder(void);
