#import "RuntimeSupport.h"
#import "FrameSocket.h"
#import "GeistScreenCaptureWire.h"

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
