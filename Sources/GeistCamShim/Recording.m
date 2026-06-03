#import "Recording.h"
#import "Util.h"

@implementation GeistCamMovieRecording
- (void)dealloc {
    if (_audioFormatHint) CFRelease(_audioFormatHint);
}
@end

static AVAssetWriterInput *makeVideoInputForFormat(CMFormatDescriptionRef fd) {
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(fd);
    NSDictionary *settings = @{
        AVVideoCodecKey:  AVVideoCodecTypeH264,
        AVVideoWidthKey:  @(dims.width),
        AVVideoHeightKey: @(dims.height),
    };
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                                   outputSettings:settings
                                                                 sourceFormatHint:fd];
    input.expectsMediaDataInRealTime = YES;
    return input;
}

static AVAssetWriterInput *makeAudioInputForFormat(CMFormatDescriptionRef fd) {
    UInt32 sampleRate = 44100;
    UInt32 channelCount = 1;
    if (fd) {
        const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd);
        if (asbd) {
            sampleRate = (UInt32)asbd->mSampleRate;
            channelCount = asbd->mChannelsPerFrame;
        }
    }
    AudioChannelLayout layout = {0};
    layout.mChannelLayoutTag = (channelCount == 2) ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_Mono;
    NSDictionary *settings = @{
        AVFormatIDKey:         @(kAudioFormatMPEG4AAC),
        AVSampleRateKey:       @(sampleRate),
        AVNumberOfChannelsKey: @(channelCount),
        AVChannelLayoutKey:    [NSData dataWithBytes:&layout length:sizeof(layout)],
    };
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                                   outputSettings:settings
                                                                 sourceFormatHint:fd];
    input.expectsMediaDataInRealTime = YES;
    return input;
}

// NO when we can't start yet (audio arrived before video) or init failed —
// caller skips the append.
static BOOL startWriterIfNeeded(GeistCamMovieRecording *rec, GeistCamSource *src, CMSampleBufferRef sb) {
    @synchronized (rec) {
        if (rec.writer != nil) return rec.writerStarted;
        CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
        if (src->kind == GeistCamSourceKind_Audio) {
            if (!rec.audioFormatHint && fd) { CFRetain(fd); rec.audioFormatHint = fd; }
            return NO;     // wait for first video frame to anchor the timeline
        }
        if (!fd) return NO;
        NSError *err = nil;
        AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:rec.outputURL fileType:AVFileTypeQuickTimeMovie error:&err];
        if (!writer) {
            geistcam_warnf("recording: AVAssetWriter init failed: %s", err.localizedDescription.UTF8String ?: "(unknown)");
            rec.active = NO;
            return NO;
        }
        AVAssetWriterInput *videoInput = makeVideoInputForFormat(fd);
        AVAssetWriterInput *audioInput = makeAudioInputForFormat(rec.audioFormatHint);
        if ([writer canAddInput:videoInput]) [writer addInput:videoInput];
        if ([writer canAddInput:audioInput]) [writer addInput:audioInput];
        if (![writer startWriting]) {
            geistcam_warnf("recording: startWriting failed: %s", writer.error.localizedDescription.UTF8String ?: "(unknown)");
            rec.active = NO;
            return NO;
        }
        rec.writer = writer;
        rec.videoInput = videoInput;
        rec.audioInput = audioInput;
        rec.startPTS = CMSampleBufferGetPresentationTimeStamp(sb);
        rec.videoElapsedSec = 0;
        rec.audioElapsedSec = 0;
        rec.videoLastSrcPTS = kCMTimeInvalid;
        rec.audioLastSrcPTS = kCMTimeInvalid;
        [writer startSessionAtSourceTime:rec.startPTS];
        rec.writerStarted = YES;
        CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(fd);
        geistcam_markerf("recording: writer started %dx%d", dims.width, dims.height);
        return YES;
    }
}

// Clamps loop-wraparounds and absurd jumps to one frame duration so the
// writer-PTS stays monotonic across MP4 loops.
static double advanceElapsed(double elapsed, CMTime lastSrc, CMTime curSrc, double frameDur) {
    if (!CMTIME_IS_VALID(lastSrc)) return elapsed;
    double delta = CMTimeGetSeconds(CMTimeSubtract(curSrc, lastSrc));
    if (delta <= 0 || delta > 1.0) delta = frameDur;
    return elapsed + delta;
}

void appendToRecording(GeistCamMovieRecording *rec, GeistCamSource *src,
                       CMSampleBufferRef sb, CMTime originalSrcPTS) {
    if (!rec || !rec.active) return;
    if (!startWriterIfNeeded(rec, src, sb)) return;

    BOOL isAudio = (src->kind == GeistCamSourceKind_Audio);
    AVAssetWriterInput *input = isAudio ? rec.audioInput : rec.videoInput;
    if (!input || !input.isReadyForMoreMediaData) return;

    double frameDur = CMTimeGetSeconds(CMSampleBufferGetDuration(sb));
    if (frameDur <= 0 || frameDur > 1.0) {
        frameDur = isAudio ? (1024.0 / 48000.0) : (src->frameRate > 0 ? 1.0 / src->frameRate : 1.0/30.0);
    }
    double elapsed = advanceElapsed(isAudio ? rec.audioElapsedSec : rec.videoElapsedSec,
                                    isAudio ? rec.audioLastSrcPTS : rec.videoLastSrcPTS,
                                    originalSrcPTS, frameDur);
    if (isAudio) {
        rec.audioElapsedSec = elapsed;
        rec.audioLastSrcPTS = originalSrcPTS;
    } else {
        rec.videoElapsedSec = elapsed;
        rec.videoLastSrcPTS = originalSrcPTS;
    }

    CMSampleTimingInfo timing = {
        .duration = CMSampleBufferGetDuration(sb),
        .presentationTimeStamp = CMTimeAdd(rec.startPTS, CMTimeMakeWithSeconds(elapsed, 600)),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef restamped = NULL;
    if (CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, sb, 1, &timing, &restamped) == 0 && restamped) {
        [input appendSampleBuffer:restamped];
        CFRelease(restamped);
    }
}
