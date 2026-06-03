#ifndef SimDisplayIOSurfaceRenderable_Protocol_h
#define SimDisplayIOSurfaceRenderable_Protocol_h
@import Foundation;
@import IOSurface;

#include "NSObject-Protocol.h"

@class IOSurface;

@protocol SimDisplayIOSurfaceRenderable <NSObject>

@required

@property (nullable, readonly) IOSurface *framebufferSurface;
@property (nullable, readonly) IOSurface *ioSurface;

@end

#endif /* SimDisplayIOSurfaceRenderable_Protocol_h */
