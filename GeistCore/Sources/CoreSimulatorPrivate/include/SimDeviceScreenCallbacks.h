//
//  Reverse-engineered ObjC protocols from CoreSimulator.framework.
//  These protocols are implemented by objects returned from SimDevice's
//  IO subsystem (accessed via SimulatorKit.framework's screenAdapter extension).
//
#ifndef SimDeviceScreenCallbacks_h
#define SimDeviceScreenCallbacks_h

@import Foundation;
@import IOSurface;

@class SimDevice;

/// Properties of a simulator screen (resolution, orientation, modes, etc.).
@protocol SimScreenProperties <NSObject>

@property (readonly) uint32_t seed;
@property (readonly) uint32_t screenID;
@property (readonly, nonnull) NSString *name;
@property (readonly, nonnull) NSString *uniqueId;
@property (readonly) int powerState;
@property (readonly) uint32_t screenType;
@property (readonly) uint32_t uiOrientation;
@property (readonly) CGSize pixelSize;
@property (readonly) double dotPitch;
@property (readonly, nullable) id maskPDF;
@property (readonly, nullable) NSDictionary *carPlayProperties;
@property (readonly, nullable) id currentMode;
@property (readonly, nonnull) NSArray *supportedScreenModes;
@property (readonly, nullable) id backlight;

@end

/// A single screen on a simulator device. Supports push-based frame
/// and surface-swap notifications via callback registration.
@protocol SimScreen <NSObject>

- (void)registerScreenCallbacksWithUUID:(nonnull NSUUID *)uuid
                          callbackQueue:(nonnull dispatch_queue_t)queue
                          frameCallback:(nonnull void (^)(void))frameCallback
                surfacesChangedCallback:(nonnull void (^)(IOSurface * _Nullable unmask, IOSurface * _Nullable masked))surfacesChanged
              propertiesChangedCallback:(nonnull void (^)(id<SimScreenProperties> _Nonnull properties))propertiesChanged;

- (void)unregisterScreenCallbacksWithUUID:(nonnull NSUUID *)uuid;

- (void)setCurrentMode:(nonnull id)mode
             pixelSize:(CGSize)size
     carPlayProperties:(nullable NSDictionary *)props
       completionQueue:(nonnull dispatch_queue_t)queue
     completionHandler:(nonnull void (^)(NSError * _Nullable error))handler;

- (void)setPowerState:(int)state
      completionQueue:(nonnull dispatch_queue_t)queue
    completionHandler:(nonnull void (^)(NSError * _Nullable error))handler;

@property (readonly, nullable) id<SimScreenProperties> screenProperties;

@end

/// Adapter providing access to a device's screens and lifecycle callbacks.
@protocol SimScreenAdapter <NSObject>

- (void)registerScreenAdapterCallbacksWithUUID:(nonnull NSUUID *)uuid
                                 callbackQueue:(nonnull dispatch_queue_t)queue
                        screenConnectedCallback:(nonnull void (^)(id<SimScreen> _Nonnull screen))connected
                  screenWillDisconnectCallback:(nonnull void (^)(id<SimScreen> _Nonnull screen))willDisconnect;

- (void)unregisterScreenAdapterCallbacksWithUUID:(nonnull NSUUID *)uuid;

- (void)enumerateScreensWithCompletionQueue:(nonnull dispatch_queue_t)queue
                          completionHandler:(nonnull void (^)(uint32_t screenID, id<SimScreen> _Nonnull screen))handler;

- (void)enumerateScreensMatching:(nullable id)predicate
                 completionQueue:(nonnull dispatch_queue_t)queue
               completionHandler:(nonnull void (^)(uint32_t screenID, id<SimScreen> _Nonnull screen))handler;

- (nonnull id)creatableScreenProperties;

- (void)createScreenWithProperties:(nonnull id<SimScreenProperties>)properties
                       currentMode:(nonnull id)mode
                         pixelSize:(CGSize)size
                 carPlayProperties:(nullable NSDictionary *)carPlay
                   completionQueue:(nonnull dispatch_queue_t)queue
                 completionHandler:(nonnull void (^)(unsigned int screenID, NSError * _Nullable error))handler;

- (void)removeScreenWithID:(uint32_t)screenID
           completionQueue:(nonnull dispatch_queue_t)queue
         completionHandler:(nonnull void (^)(NSError * _Nullable error))handler;

@end

#endif /* SimDeviceScreenCallbacks_h */
