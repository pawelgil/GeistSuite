#pragma once
#include <stdint.h>

// Must mirror Swift's MediaSourceFeatures.rawValue bits in
// Sources/Lib/MediaSource.swift. The lib encodes these into the wire's
// per-slot SlotInfo; the shim reads them back via serverGetSlotFeatures().
#define GEISTCAM_FEATURE_ALLOWS_FRONT_MIRROR (1u << 0)
