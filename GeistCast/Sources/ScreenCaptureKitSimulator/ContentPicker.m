#import "RuntimeSupport.h"
#import "FrameSocket.h"
#import "GeistScreenCaptureWire.h"

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
    return GSCKGetScreenGeometry().scale;
}

- (CGRect)contentRect {
    return GSCKGetScreenGeometry().bounds;
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
@property(nonatomic, strong) NSMapTable<SCStream *, SCContentSharingPickerConfiguration *> *streamConfigurations;
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
        state.streamConfigurations = [NSMapTable weakToStrongObjectsMapTable];
        state.configuration = [[SCContentSharingPickerConfiguration alloc] init];
        GSCKSetObject(self, &pickerStateKey, state);
    }
    return self;
}

- (GSCKPickerState *)geistState {
    return GSCKGetObject(self, &pickerStateKey);
}

- (SCContentSharingPickerConfiguration *)defaultConfiguration {
    @synchronized (self) { return [self.geistState.configuration copy]; }
}

- (void)setDefaultConfiguration:(SCContentSharingPickerConfiguration *)configuration {
    @synchronized (self) {
        self.geistState.configuration = [configuration copy]
            ?: [[SCContentSharingPickerConfiguration alloc] init];
    }
}

- (BOOL)isAvailable {
    return GSCKIsAvailable();
}

- (BOOL)isActive {
    @synchronized (self) { return self.geistState.isActive; }
}

- (void)setActive:(BOOL)active {
    @synchronized (self) {
        self.geistState.active = active;
        if (!active && self.geistState.presentationObserver) {
            [NSNotificationCenter.defaultCenter removeObserver:self.geistState.presentationObserver];
            self.geistState.presentationObserver = nil;
        }
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
    @synchronized (self) {
        if (configuration) [self.geistState.streamConfigurations setObject:[configuration copy] forKey:stream];
        else [self.geistState.streamConfigurations removeObjectForKey:stream];
    }
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

- (NSArray<id<SCContentSharingPickerObserver>> *)geistObservers {
    @synchronized (self) { return self.geistState.observers.allObjects; }
}

- (void)geistPresent {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self geistPresent]; });
        return;
    }
    if (!self.isActive) {
        NSError *error = GSCKError(SCStreamErrorFailedToStart, @"The content picker is inactive.");
        for (id<SCContentSharingPickerObserver> observer in self.geistObservers) {
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
                    @synchronized (strongSelf) {
                        id observer = strongSelf.geistState.presentationObserver;
                        strongSelf.geistState.presentationObserver = nil;
                        if (observer) [NSNotificationCenter.defaultCenter removeObserver:observer];
                    }
                    [strongSelf geistPresent];
                }];
            }
        }
        return;
    }
    SCContentFilter *filter = [[SCContentFilter alloc] init];
    for (id<SCContentSharingPickerObserver> observer in self.geistObservers) {
        [observer contentSharingPicker:self didUpdateWithFilter:filter forStream:nil];
    }
}

@end

