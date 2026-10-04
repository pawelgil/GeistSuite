#pragma once
#include <stdbool.h>
#include "GeistScreenCaptureWire.h"

bool GSCKValidateFrameHeader(const geist_sck_frame_header_t *header);
