#import "RuntimeSupport.h"
#import "FrameSocket.h"
#import "GeistScreenCaptureWire.h"

@interface GSCKOutputRegistration : NSObject
@property(nonatomic, weak) id<SCStreamOutput> output;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) dispatch_semaphore_t capacity;
@property(nonatomic, assign) BOOL removed;
@end

@implementation GSCKOutputRegistration
@end

@interface GSCKStreamConnection : NSObject
@property(nonatomic, readonly) int descriptor;
- (instancetype)initWithDescriptor:(int)descriptor;
@end

@implementation GSCKStreamConnection
- (instancetype)initWithDescriptor:(int)descriptor {
    self = [super init];
    if (self) _descriptor = descriptor;
    return self;
}
- (void)dealloc { GSCKClose(_descriptor); }
@end

@interface GSCKStreamState : NSObject
@property(nonatomic, weak) id<SCStreamDelegate> delegate;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableArray<GSCKOutputRegistration *> *> *outputs;
@property(nonatomic, strong) SCStreamConfiguration *configuration;
@property(nonatomic, strong) GSCKStreamConnection *connection;
@property(nonatomic, assign) uint64_t generation;
@property(nonatomic, assign) BOOL starting;
@property(nonatomic, assign, getter=isCapturing) BOOL capturing;
@end

@implementation GSCKStreamState

- (void)dealloc {
    if (_connection) GSCKShutdown(_connection.descriptor);
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _outputs = [NSMutableDictionary dictionary];
    }
    return self;
}

@end

@implementation SCStream

static char streamStateKey;

- (instancetype)initWithFilter:(SCContentFilter *)contentFilter
                  configuration:(SCStreamConfiguration *)streamConfig
                       delegate:(id<SCStreamDelegate>)delegate {
    self = [super init];
    if (self) {
        GSCKStreamState *state = [[GSCKStreamState alloc] init];
        state.delegate = delegate;
        state.configuration = streamConfig;
        GSCKSetObject(self, &streamStateKey, state);
    }
    return self;
}

- (GSCKStreamState *)geistState {
    return GSCKGetObject(self, &streamStateKey);
}

- (CMClockRef)synchronizationClock {
    return CMClockGetHostTimeClock();
}

- (BOOL)isCapturing {
    @synchronized (self) { return self.geistState.isCapturing; }
}

- (BOOL)addStreamOutput:(id<SCStreamOutput>)output
                   type:(SCStreamOutputType)type
     sampleHandlerQueue:(dispatch_queue_t)sampleHandlerQueue
                  error:(NSError **)error {
    if (type < SCStreamOutputTypeScreen || type > SCStreamOutputTypeMicrophone) {
        if (error) *error = GSCKError(SCStreamErrorInvalidParameter, @"Unknown stream output type.");
        return NO;
    }
    GSCKOutputRegistration *registration = [[GSCKOutputRegistration alloc] init];
    registration.output = output;
    registration.queue = sampleHandlerQueue ?: dispatch_get_main_queue();
    registration.capacity = dispatch_semaphore_create(3);
    @synchronized (self) {
        NSNumber *key = @(type);
        NSMutableArray *registrations = self.geistState.outputs[key];
        if (!registrations) {
            registrations = [NSMutableArray array];
            self.geistState.outputs[key] = registrations;
        }
        for (GSCKOutputRegistration *existing in registrations) {
            if (existing.output == output) {
                if (error) *error = GSCKError(SCStreamErrorInvalidParameter, @"Output is already registered.");
                return NO;
            }
        }
        if ((self.geistState.isCapturing || self.geistState.starting) && registrations.count == 0) {
            if (error) *error = GSCKError(SCStreamErrorNotSupported, @"Stop capture before adding a new output type.");
            return NO;
        }
        [registrations addObject:registration];
    }
    return YES;
}

- (BOOL)removeStreamOutput:(id<SCStreamOutput>)output
                      type:(SCStreamOutputType)type
                     error:(NSError **)error {
    @synchronized (self) {
        NSMutableArray *registrations = self.geistState.outputs[@(type)];
        NSIndexSet *indexes = [registrations indexesOfObjectsPassingTest:
            ^BOOL(GSCKOutputRegistration *registration, NSUInteger index, BOOL *stop) {
                if (registration.output != output) return NO;
                registration.removed = YES;
                return YES;
            }];
        if (indexes.count == 0) {
            if (error) *error = GSCKError(SCStreamErrorRemovingStream, @"Output is not registered.");
            return NO;
        }
        [registrations removeObjectsAtIndexes:indexes];
    }
    return YES;
}

- (void)startCaptureWithCompletionHandler:(void (^)(NSError *))completionHandler {
    uint32_t outputs = 0;
    uint64_t generation = 0;
    NSError *error = nil;
    @synchronized (self) {
        GSCKStreamState *state = self.geistState;
        if (state.isCapturing || state.starting) {
            error = GSCKError(SCStreamErrorAttemptToStartStreamState, @"The stream is already starting or capturing.");
        } else {
            for (NSNumber *type in state.outputs) {
                for (GSCKOutputRegistration *registration in state.outputs[type]) {
                    if (registration.output) outputs |= 1u << type.unsignedIntValue;
                }
            }
            if (!outputs) {
                error = GSCKError(SCStreamErrorInvalidParameter, @"The stream has no outputs.");
            } else {
                state.starting = YES;
                generation = ++state.generation;
            }
        }
    }
    if (error) {
        if (completionHandler) completionHandler(error);
        return;
    }

    GSCKScreenGeometry geometry = GSCKGetScreenGeometry();
    CGFloat scale = geometry.scale;
    SCStreamConfiguration *configuration = self.geistState.configuration;
    BOOL screenSizeUnsupported = (outputs & GEIST_SCK_OUTPUT_SCREEN) && geometry.available &&
        (configuration.width != geometry.nativeBounds.size.width || configuration.height != geometry.nativeBounds.size.height);
    BOOL microphoneFormatUnsupported = (outputs & GEIST_SCK_OUTPUT_MICROPHONE) &&
        (configuration.sampleRate != 48000 || configuration.channelCount != 1);
    if (screenSizeUnsupported || microphoneFormatUnsupported || configuration.captureDynamicRange != 0 ||
        configuration.capturesAudio || (outputs & GEIST_SCK_OUTPUT_AUDIO)) {
        @synchronized (self) {
            if (self.geistState.generation == generation) self.geistState.starting = NO;
        }
        if (completionHandler) completionHandler(GSCKError(SCStreamErrorNotSupported,
            @"GeistCast supports native-size SDR video and 48 kHz mono microphone audio; app audio is unavailable."));
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int32_t status = GEIST_SCK_STATUS_FAILED;
        int socket = GSCKConnect(outputs, &status);
        GSCKStreamConnection *connection = socket >= 0 ? [[GSCKStreamConnection alloc] initWithDescriptor:socket] : nil;
        NSError *failure = nil;
        @synchronized (self) {
            GSCKStreamState *state = self.geistState;
            if (state.generation != generation) {
                failure = GSCKError(SCStreamErrorAttemptToStartStreamState, @"Capture was stopped while starting.");
            } else {
                state.starting = NO;
                if (socket < 0) {
                    failure = GSCKError(status == GEIST_SCK_STATUS_NOT_SUPPORTED
                        ? SCStreamErrorNotSupported : SCStreamErrorFailedToStart,
                        @"GeistCast could not start capture for this simulator.");
                } else {
                    state.connection = connection;
                    state.capturing = YES;
                }
            }
        }
        if (!failure) [self geistReadSamplesFromConnection:connection scale:scale generation:generation];
        if (completionHandler) completionHandler(failure);
    });
}

- (void)stopCaptureWithCompletionHandler:(void (^)(NSError *))completionHandler {
    @synchronized (self) {
        GSCKStreamState *state = self.geistState;
        ++state.generation;
        state.starting = NO;
        state.capturing = NO;
        if (state.connection) GSCKShutdown(state.connection.descriptor);
        state.connection = nil;
    }
    if (completionHandler) completionHandler(nil);
}

- (void)geistReadSamplesFromConnection:(GSCKStreamConnection *)connection scale:(CGFloat)scale generation:(uint64_t)generation {
    __weak SCStream *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        while (true) {
            @autoreleasepool {
                GSCKDeliveredSample sample = GSCKReadNextSample(connection.descriptor, scale);
                if (!sample.sampleBuffer) break;
                SCStream *stream = weakSelf;
                BOOL active = NO;
                NSArray<GSCKOutputRegistration *> *registrations;
                @synchronized (stream) {
                    active = stream.geistState.isCapturing && stream.geistState.generation == generation;
                    registrations = [stream.geistState.outputs[@(sample.type)] copy];
                }
                if (!active) {
                    CFRelease(sample.sampleBuffer);
                    break;
                }
                for (GSCKOutputRegistration *registration in registrations) {
                    if (dispatch_semaphore_wait(registration.capacity, DISPATCH_TIME_NOW) != 0) continue;
                    CFRetain(sample.sampleBuffer);
                    dispatch_async(registration.queue, ^{
                        SCStream *current = weakSelf;
                        id<SCStreamOutput> output = nil;
                        @synchronized (current) {
                            if (current.geistState.isCapturing && current.geistState.generation == generation &&
                                !registration.removed) output = registration.output;
                        }
                        if ([output respondsToSelector:@selector(stream:didOutputSampleBuffer:ofType:)]) {
                            [output stream:current didOutputSampleBuffer:sample.sampleBuffer ofType:sample.type];
                        }
                        CFRelease(sample.sampleBuffer);
                        dispatch_semaphore_signal(registration.capacity);
                    });
                }
                CFRelease(sample.sampleBuffer);
            }
        }
        SCStream *stream = weakSelf;
        id<SCStreamDelegate> delegate = nil;
        @synchronized (stream) {
            if (stream.geistState.isCapturing && stream.geistState.generation == generation) {
                stream.geistState.capturing = NO;
                stream.geistState.connection = nil;
                delegate = stream.geistState.delegate;
            }
        }
        if ([delegate respondsToSelector:@selector(stream:didStopWithError:)]) {
            [delegate stream:stream didStopWithError:GSCKError(
                SCStreamErrorSystemStoppedStream, @"The GeistCast capture session ended.")];
        }
    });
}

- (BOOL)addRecordingOutput:(SCRecordingOutput *)output error:(NSError **)error {
    if (error) *error = GSCKError(SCStreamErrorNotSupported, @"Recording output is not supported in Simulator.");
    return NO;
}

- (BOOL)removeRecordingOutput:(SCRecordingOutput *)output error:(NSError **)error {
    if (error) *error = GSCKError(SCStreamErrorNotSupported, @"Recording output is not supported in Simulator.");
    return NO;
}

- (BOOL)addClipBufferingOutput:(SCClipBufferingOutput *)output error:(NSError **)error {
    if (error) *error = GSCKError(SCStreamErrorNotSupported, @"Clip buffering is not supported in Simulator.");
    return NO;
}

- (BOOL)removeClipBufferingOutput:(SCClipBufferingOutput *)output error:(NSError **)error {
    if (error) *error = GSCKError(SCStreamErrorNotSupported, @"Clip buffering is not supported in Simulator.");
    return NO;
}

- (BOOL)addVideoEffectOutput:(SCVideoEffectOutput *)output error:(NSError **)error {
    if (error) *error = GSCKError(SCStreamErrorNotSupported, @"Camera effects are not supported in Simulator.");
    return NO;
}

- (BOOL)removeVideoEffectOutput:(SCVideoEffectOutput *)output error:(NSError **)error {
    if (error) *error = GSCKError(SCStreamErrorNotSupported, @"Camera effects are not supported in Simulator.");
    return NO;
}

@end

