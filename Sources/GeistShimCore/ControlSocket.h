#pragma once

#import <Foundation/Foundation.h>
#include <stdatomic.h>

// -1 when not connected.
extern atomic_int gControlFD;

// $GEISTCAST_SOCKET if set; otherwise derived from $SIMULATOR_UDID + the
// main bundle identifier so both sides agree without a handshake.
const char *GC_ControlSocketPath(void);

// Caller must send the role handshake (helloHost / helloExtension) after
// open — the session can't disambiguate connections otherwise.
BOOL GC_OpenControlConnection(void);

// Best-effort: silently drops when the connection isn't open.
void GC_WriteControlLine(NSString *jsonLine);

// `carryOver` holds bytes left over from a previous read. Returns nil on
// socket close or parse failure.
NSDictionary *GC_ReadControlMessage(NSMutableData *carryOver);

// Atomically close gControlFD iff it currently equals `fd`. Prevents the
// caller from closing an fd number that's already been reassigned to a
// fresh connection.
void GC_CloseControlFDIfMatches(int fd);
