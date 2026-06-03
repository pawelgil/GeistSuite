#ifndef SimDeviceIOPortInterface_Protocol_h
#define SimDeviceIOPortInterface_Protocol_h
@import Foundation;

#include "NSObject-Protocol.h"

@class NSUUID;

@protocol SimDeviceIOPortInterface <NSObject>

@required

@property (readonly, nonatomic) id descriptor;
@property (readonly, nonatomic) NSUUID *uuid;
@property (readonly, nonatomic) unsigned short ioPortClass;

@end

#endif /* SimDeviceIOPortInterface_Protocol_h */
