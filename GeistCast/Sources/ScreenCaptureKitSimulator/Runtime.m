#import "FrameSocket.h"
#import "GeistScreenCaptureWire.h"

#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <objc/runtime.h>

NSErrorDomain const SCStreamErrorDomain = @"com.apple.ScreenCaptureKit.SCStreamErrorDomain";
SCStreamFrameInfo const SCStreamFrameInfoStatus = @"SCStreamFrameInfoStatus";
SCStreamFrameInfo const SCStreamFrameInfoDisplayTime = @"SCStreamFrameInfoDisplayTime";
SCStreamFrameInfo const SCStreamFrameInfoScaleFactor = @"SCStreamFrameInfoScaleFactor";
SCStreamFrameInfo const SCStreamFrameInfoContentScale = @"SCStreamFrameInfoContentScale";
SCStreamFrameInfo const SCStreamFrameInfoContentRect = @"SCStreamFrameInfoContentRect";
SCStreamFrameInfo const SCStreamFrameInfoScreenRect = @"SCStreamFrameInfoScreenRect";
SCStreamFrameInfo const SCStreamFrameInfoVideoOrientation = @"SCStreamFrameInfoVideoOrientation";

static NSError *GSCKError(SCStreamErrorCode code, NSString *description) {
    return [NSError errorWithDomain:SCStreamErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

static void GSCKSetObject(id object, const void *key, id value) {
    objc_setAssociatedObject(object, key, value, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static id GSCKGetObject(id object, const void *key) {
    return objc_getAssociatedObject(object, key);
}

static UIScreen *GSCKActiveScreen(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            return ((UIWindowScene *)scene).screen;
        }
    }
    return nil;
}

@implementation SCContentSharingPickerConfiguration

static char pickerMicrophoneKey;
static char pickerCameraKey;

- (instancetype)init {
    return [super init];
}

- (id)copyWithZone:(NSZone *)zone {
    SCContentSharingPickerConfiguration *copy = [[SCContentSharingPickerConfiguration alloc] init];
    copy.showsMicrophoneControl = self.showsMicrophoneControl;
    copy.showsCameraControl = self.showsCameraControl;
    return copy;
}

- (BOOL)showsMicrophoneControl {
    return [GSCKGetObject(self, &pickerMicrophoneKey) boolValue];
}

- (void)setShowsMicrophoneControl:(BOOL)value {
    GSCKSetObject(self, &pickerMicrophoneKey, @(value));
}

- (BOOL)showsCameraControl {
    return [GSCKGetObject(self, &pickerCameraKey) boolValue];
}

- (void)setShowsCameraControl:(BOOL)value {
    GSCKSetObject(self, &pickerCameraKey, @(value));
}

@end

@implementation SCContentFilter

- (SCShareableContentStyle)style {
    return SCShareableContentStyleDisplay;
}

- (float)pointPixelScale {
    UIScreen *screen = GSCKActiveScreen();
    return screen ? screen.scale : 1;
}

- (CGRect)contentRect {
    UIScreen *screen = GSCKActiveScreen();
    return screen ? screen.bounds : CGRectZero;
}

- (BOOL)isMicrophoneEnabled {
    return YES;
}

- (BOOL)isCameraEnabled {
    return NO;
}

@end

@interface SCContentSharingPicker (GeistPrivate)
- (instancetype)initGeist;
@end

@interface GSCKPickerState : NSObject
@property(nonatomic, strong) NSHashTable<id<SCContentSharingPickerObserver>> *observers;
@property(nonatomic, copy) SCContentSharingPickerConfiguration *configuration;
@property(nonatomic, strong) id presentationObserver;
@property(nonatomic, assign, getter=isActive) BOOL active;
@end

@implementation GSCKPickerState
@end

@implementation SCContentSharingPicker

static char pickerStateKey;

+ (instancetype)sharedPicker {
    static SCContentSharingPicker *picker;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        picker = [class_createInstance(self, 0) initGeist];
    });
    return picker;
}

- (instancetype)initGeist {
    self = [super init];
    if (self) {
        GSCKPickerState *state = [[GSCKPickerState alloc] init];
        state.observers = [NSHashTable weakObjectsHashTable];
        state.configuration = [[SCContentSharingPickerConfiguration alloc] init];
        GSCKSetObject(self, &pickerStateKey, state);
    }
    return self;
}

- (GSCKPickerState *)geistState {
    return GSCKGetObject(self, &pickerStateKey);
}

- (SCContentSharingPickerConfiguration *)defaultConfiguration {
    return self.geistState.configuration;
}

- (void)setDefaultConfiguration:(SCContentSharingPickerConfiguration *)configuration {
    self.geistState.configuration = [configuration copy]
        ?: [[SCContentSharingPickerConfiguration alloc] init];
}

- (BOOL)isAvailable {
    return GSCKIsAvailable();
}

- (BOOL)isActive {
    return self.geistState.isActive;
}

- (void)setActive:(BOOL)active {
    self.geistState.active = active;
    if (!active && self.geistState.presentationObserver) {
        [NSNotificationCenter.defaultCenter removeObserver:self.geistState.presentationObserver];
        self.geistState.presentationObserver = nil;
    }
}

- (void)addObserver:(id<SCContentSharingPickerObserver>)observer {
    @synchronized (self) {
        [self.geistState.observers addObject:observer];
    }
}

- (void)removeObserver:(id<SCContentSharingPickerObserver>)observer {
    @synchronized (self) {
        [self.geistState.observers removeObject:observer];
    }
}

- (void)setConfiguration:(SCContentSharingPickerConfiguration *)configuration
                forStream:(SCStream *)stream {
    self.defaultConfiguration = configuration;
}

- (void)present {
    [self geistPresent];
}

- (void)presentPickerUsingContentStyle:(SCShareableContentStyle)contentStyle {
    [self geistPresent];
}

- (void)presentPickerForCurrentApplication {
    [self geistPresent];
}

- (void)geistPresent {
    if (!self.isActive) {
        NSError *error = GSCKError(SCStreamErrorFailedToStart, @"The content picker is inactive.");
        for (id<SCContentSharingPickerObserver> observer in self.geistState.observers.allObjects) {
            [observer contentSharingPickerStartDidFailWithError:error];
        }
        return;
    }
    if (!GSCKActiveScreen()) {
        @synchronized (self) {
            if (!self.geistState.presentationObserver) {
                __weak SCContentSharingPicker *weakSelf = self;
                self.geistState.presentationObserver =
                    [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidActivateNotification
                                                                    object:nil
                                                                     queue:NSOperationQueue.mainQueue
                                                                usingBlock:^(__unused NSNotification *notification) {
                    SCContentSharingPicker *strongSelf = weakSelf;
                    id observer = strongSelf.geistState.presentationObserver;
                    strongSelf.geistState.presentationObserver = nil;
                    if (observer) {
                        [NSNotificationCenter.defaultCenter removeObserver:observer];
                    }
                    [strongSelf geistPresent];
                }];
            }
        }
        return;
    }
    SCContentFilter *filter = [[SCContentFilter alloc] init];
    for (id<SCContentSharingPickerObserver> observer in self.geistState.observers.allObjects) {
        [observer contentSharingPicker:self didUpdateWithFilter:filter forStream:nil];
    }
}

@end

@implementation SCStreamConfiguration

static char streamCapturesAudioKey;
static char streamSampleRateKey;
static char streamChannelCountKey;
static char streamExcludesAudioKey;
static char streamDynamicRangeKey;
static char streamWidthKey;
static char streamHeightKey;

+ (instancetype)streamConfigurationWithPreset:(SCStreamConfigurationPreset)preset {
    return [[self alloc] init];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.sampleRate = 48000;
        self.channelCount = 1;
        UIScreen *screen = GSCKActiveScreen();
        self.width = (size_t)screen.nativeBounds.size.width;
        self.height = (size_t)screen.nativeBounds.size.height;
    }
    return self;
}

- (BOOL)capturesAudio { return [GSCKGetObject(self, &streamCapturesAudioKey) boolValue]; }
- (void)setCapturesAudio:(BOOL)value { GSCKSetObject(self, &streamCapturesAudioKey, @(value)); }
- (NSInteger)sampleRate { return [GSCKGetObject(self, &streamSampleRateKey) integerValue]; }
- (void)setSampleRate:(NSInteger)value { GSCKSetObject(self, &streamSampleRateKey, @(value)); }
- (NSInteger)channelCount { return [GSCKGetObject(self, &streamChannelCountKey) integerValue]; }
- (void)setChannelCount:(NSInteger)value { GSCKSetObject(self, &streamChannelCountKey, @(value)); }
- (BOOL)excludesCurrentProcessAudio { return [GSCKGetObject(self, &streamExcludesAudioKey) boolValue]; }
- (void)setExcludesCurrentProcessAudio:(BOOL)value { GSCKSetObject(self, &streamExcludesAudioKey, @(value)); }
- (SCCaptureDynamicRange)captureDynamicRange { return [GSCKGetObject(self, &streamDynamicRangeKey) integerValue]; }
- (void)setCaptureDynamicRange:(SCCaptureDynamicRange)value { GSCKSetObject(self, &streamDynamicRangeKey, @(value)); }
- (size_t)width { return [GSCKGetObject(self, &streamWidthKey) unsignedLongLongValue]; }
- (void)setWidth:(size_t)value { GSCKSetObject(self, &streamWidthKey, @(value)); }
- (size_t)height { return [GSCKGetObject(self, &streamHeightKey) unsignedLongLongValue]; }
- (void)setHeight:(size_t)value { GSCKSetObject(self, &streamHeightKey, @(value)); }

@end

@interface GSCKOutputRegistration : NSObject
@property(nonatomic, weak) id<SCStreamOutput> output;
@property(nonatomic, strong) dispatch_queue_t queue;
@end

@implementation GSCKOutputRegistration
@end

@interface GSCKStreamState : NSObject
@property(nonatomic, weak) id<SCStreamDelegate> delegate;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableArray<GSCKOutputRegistration *> *> *outputs;
@property(nonatomic, strong) SCStreamConfiguration *configuration;
@property(nonatomic, assign) int socket;
@property(nonatomic, assign, getter=isCapturing) BOOL capturing;
@end

@implementation GSCKStreamState

- (instancetype)init {
    self = [super init];
    if (self) {
        _outputs = [NSMutableDictionary dictionary];
        _socket = -1;
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
    return self.geistState.isCapturing;
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
    @synchronized (self) {
        NSNumber *key = @(type);
        NSMutableArray *registrations = self.geistState.outputs[key];
        if (!registrations) {
            registrations = [NSMutableArray array];
            self.geistState.outputs[key] = registrations;
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
                return registration.output == output;
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
    @synchronized (self) {
        if (self.geistState.isCapturing) {
            if (completionHandler) completionHandler(GSCKError(
                SCStreamErrorAttemptToStartStreamState, @"The stream is already capturing."
            ));
            return;
        }
    }

    uint32_t outputs = 0;
    @synchronized (self) {
        if (self.geistState.outputs[@(SCStreamOutputTypeScreen)].count > 0) {
            outputs |= GEIST_SCK_OUTPUT_SCREEN;
        }
        if (self.geistState.outputs[@(SCStreamOutputTypeAudio)].count > 0) {
            outputs |= GEIST_SCK_OUTPUT_AUDIO;
        }
        if (self.geistState.outputs[@(SCStreamOutputTypeMicrophone)].count > 0) {
            outputs |= GEIST_SCK_OUTPUT_MICROPHONE;
        }
    }
    if (outputs == 0) {
        if (completionHandler) completionHandler(GSCKError(
            SCStreamErrorInvalidParameter, @"The stream has no outputs."
        ));
        return;
    }

    UIScreen *screen = GSCKActiveScreen();
    SCStreamConfiguration *configuration = self.geistState.configuration;
    BOOL screenSizeUnsupported = screen && (configuration.width != screen.nativeBounds.size.width ||
                                             configuration.height != screen.nativeBounds.size.height);
    BOOL microphoneFormatUnsupported = (outputs & GEIST_SCK_OUTPUT_MICROPHONE) &&
        (configuration.sampleRate != 48000 || configuration.channelCount != 1);
    if (screenSizeUnsupported || microphoneFormatUnsupported || configuration.captureDynamicRange != 0) {
        if (completionHandler) completionHandler(GSCKError(
            SCStreamErrorNotSupported,
            @"GeistCast currently supports native-size SDR video and 48 kHz mono microphone audio."
        ));
        return;
    }

    int32_t status = GEIST_SCK_STATUS_FAILED;
    int socket = GSCKConnect(outputs, &status);
    if (socket < 0) {
        SCStreamErrorCode code = status == GEIST_SCK_STATUS_NOT_SUPPORTED
            ? SCStreamErrorNotSupported : SCStreamErrorFailedToStart;
        if (completionHandler) completionHandler(GSCKError(
            code, status == GEIST_SCK_STATUS_NOT_SUPPORTED
                ? @"This ScreenCaptureKit output is not supported by GeistCast."
                : @"GeistCast is not available for this simulator."
        ));
        return;
    }

    @synchronized (self) {
        self.geistState.socket = socket;
        self.geistState.capturing = YES;
    }
    [self geistReadSamplesFromSocket:socket];
    if (completionHandler) completionHandler(nil);
}

- (void)stopCaptureWithCompletionHandler:(void (^)(NSError *))completionHandler {
    int socket;
    @synchronized (self) {
        if (!self.geistState.isCapturing) {
            if (completionHandler) completionHandler(nil);
            return;
        }
        socket = self.geistState.socket;
        self.geistState.socket = -1;
        self.geistState.capturing = NO;
    }
    GSCKShutdown(socket);
    if (completionHandler) completionHandler(nil);
}

- (void)geistReadSamplesFromSocket:(int)socket {
    __weak SCStream *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        while (true) {
            GSCKDeliveredSample sample = GSCKReadNextSample(socket);
            if (!sample.sampleBuffer) break;
            SCStream *stream = weakSelf;
            if (!stream) {
                CFRelease(sample.sampleBuffer);
                break;
            }
            NSArray<GSCKOutputRegistration *> *registrations;
            @synchronized (stream) {
                registrations = [stream.geistState.outputs[@(sample.type)] copy] ?: @[];
            }
            for (GSCKOutputRegistration *registration in registrations) {
                id<SCStreamOutput> output = registration.output;
                if (!output) continue;
                CFRetain(sample.sampleBuffer);
                dispatch_async(registration.queue, ^{
                    [output stream:stream didOutputSampleBuffer:sample.sampleBuffer ofType:sample.type];
                    CFRelease(sample.sampleBuffer);
                });
            }
            CFRelease(sample.sampleBuffer);
        }
        GSCKClose(socket);
        SCStream *stream = weakSelf;
        if (!stream) return;
        BOOL unexpected;
        @synchronized (stream) {
            unexpected = stream.geistState.isCapturing && stream.geistState.socket == socket;
            if (unexpected) {
                stream.geistState.capturing = NO;
                stream.geistState.socket = -1;
            }
        }
        if (unexpected && [stream.geistState.delegate respondsToSelector:@selector(stream:didStopWithError:)]) {
            [stream.geistState.delegate stream:stream didStopWithError:GSCKError(
                SCStreamErrorSystemStoppedStream, @"The GeistCast capture session ended."
            )];
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

@implementation SCRecordingOutputConfiguration

static char recordingURLKey;
static char recordingCodecKey;
static char recordingFileTypeKey;
static char recordingMixesAudioKey;

- (instancetype)init {
    self = [super init];
    if (self) {
        self.videoCodecType = AVVideoCodecTypeH264;
        self.outputFileType = AVFileTypeMPEG4;
        self.mixesAudioWithMicrophone = YES;
    }
    return self;
}

- (NSURL *)outputURL { return GSCKGetObject(self, &recordingURLKey); }
- (void)setOutputURL:(NSURL *)value { GSCKSetObject(self, &recordingURLKey, [value copy]); }
- (AVVideoCodecType)videoCodecType { return GSCKGetObject(self, &recordingCodecKey); }
- (void)setVideoCodecType:(AVVideoCodecType)value { GSCKSetObject(self, &recordingCodecKey, [value copy]); }
- (AVFileType)outputFileType { return GSCKGetObject(self, &recordingFileTypeKey); }
- (void)setOutputFileType:(AVFileType)value { GSCKSetObject(self, &recordingFileTypeKey, [value copy]); }
- (NSArray<AVVideoCodecType> *)availableVideoCodecTypes { return @[AVVideoCodecTypeH264]; }
- (NSArray<AVFileType> *)availableOutputFileTypes { return @[AVFileTypeMPEG4]; }
- (BOOL)mixesAudioWithMicrophone { return [GSCKGetObject(self, &recordingMixesAudioKey) boolValue]; }
- (void)setMixesAudioWithMicrophone:(BOOL)value { GSCKSetObject(self, &recordingMixesAudioKey, @(value)); }

@end

@implementation SCRecordingOutput

- (instancetype)initWithConfiguration:(SCRecordingOutputConfiguration *)configuration
                              delegate:(id<SCRecordingOutputDelegate>)delegate {
    return [super init];
}

- (CMTime)recordedDuration { return kCMTimeZero; }
- (NSInteger)recordedFileSize { return 0; }

@end

@implementation SCClipBufferingOutput

- (instancetype)initWithDelegate:(id<SCClipBufferingOutputDelegate>)delegate {
    return [super init];
}

- (void)exportClipToURL:(NSURL *)url
               duration:(NSTimeInterval)duration
      completionHandler:(void (^)(NSError *))completionHandler {
    if (completionHandler) completionHandler(GSCKError(
        SCStreamErrorNotSupported, @"Clip buffering is not supported in Simulator."
    ));
}

@end

@implementation SCVideoEffectOutput

static char videoEffectCameraKey;

- (instancetype)initWithCameraDevice:(AVCaptureDevice *)device {
    self = [super init];
    if (self) self.cameraDevice = device;
    return self;
}

- (AVCaptureDevice *)cameraDevice { return GSCKGetObject(self, &videoEffectCameraKey); }
- (void)setCameraDevice:(AVCaptureDevice *)value { GSCKSetObject(self, &videoEffectCameraKey, value); }

@end

@interface GSCKRecordingEditorState : NSObject
@property(nonatomic, weak) id<SCRecordingEditorDelegate> delegate;
@end

@implementation GSCKRecordingEditorState
@end

@implementation SCRecordingEditor

static char recordingEditorDelegateKey;

- (instancetype)initWithURL:(NSURL *)url {
    self = [super init];
    if (self) {
        GSCKSetObject(self, &recordingEditorDelegateKey, [[GSCKRecordingEditorState alloc] init]);
    }
    return self;
}

- (id<SCRecordingEditorDelegate>)delegate {
    GSCKRecordingEditorState *state = GSCKGetObject(self, &recordingEditorDelegateKey);
    return state.delegate;
}

- (void)setDelegate:(id<SCRecordingEditorDelegate>)delegate {
    GSCKRecordingEditorState *state = GSCKGetObject(self, &recordingEditorDelegateKey);
    state.delegate = delegate;
}

- (void)presentFromWindowScene:(UIWindowScene *)windowScene
             completionHandler:(void (^)(NSError *))completionHandler {
    NSError *error = GSCKError(
        SCStreamErrorNotSupported, @"Recording preview is not supported in Simulator."
    );
    if (completionHandler) completionHandler(error);
    id<SCRecordingEditorDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(recordingEditor:didFailWithError:)]) {
        [delegate recordingEditor:self didFailWithError:error];
    }
}

@end
