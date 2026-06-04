#ifndef SimDisplayRenderable_Protocol_h
#define SimDisplayRenderable_Protocol_h
@import Foundation;
@import CoreGraphics;

#include "NSObject-Protocol.h"

@protocol SimDisplayRenderable <NSObject>

@required

@property (readonly) CGSize displaySize;

@end

#endif /* SimDisplayRenderable_Protocol_h */
