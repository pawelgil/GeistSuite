#import "RuntimeSupport.h"
#import "FrameSocket.h"
#import "GeistScreenCaptureWire.h"

@implementation SCStreamConfiguration

static char streamCapturesAudioKey;
static char streamSampleRateKey;
static char streamChannelCountKey;
static char streamExcludesAudioKey;
static char streamDynamicRangeKey;
static char streamWidthKey;
static char streamHeightKey;

+ (instancetype)streamConfigurationWithPreset:(SCStreamConfigurationPreset)preset {
    SCStreamConfiguration *configuration = [[self alloc] init];
    configuration.captureDynamicRange = SCCaptureDynamicRangeHDRCanonicalDisplay;
    return configuration;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.sampleRate = 48000;
        self.channelCount = 1;
        GSCKScreenGeometry screen = GSCKGetScreenGeometry();
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

