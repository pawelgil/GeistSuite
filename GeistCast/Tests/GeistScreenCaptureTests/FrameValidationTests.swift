import GeistScreenCaptureShimCore
import Testing

struct FrameValidationTests {
    @Test
    func validate_ValidBGRAFrame_AcceptsHeader() {
        var header = videoHeader()
        #expect(GSCKValidateFrameHeader(&header))
    }

    @Test(arguments: [UInt32(0), 3, UInt32.max])
    func validate_InvalidVideoStride_RejectsHeader(stride: UInt32) {
        var header = videoHeader()
        header.bytesPerRowPlane0 = stride
        #expect(!GSCKValidateFrameHeader(&header))
    }

    @Test
    func validate_TruncatedAudio_RejectsHeader() {
        var header = audioHeader()
        header.payloadSize = 4
        #expect(!GSCKValidateFrameHeader(&header))
    }

    @Test
    func validate_OverflowingAudioSize_RejectsHeader() {
        var header = audioHeader()
        header.audioSampleCount = UInt32.max
        #expect(!GSCKValidateFrameHeader(&header))
    }

    @Test
    func validate_ValidAudio_AcceptsHeader() {
        var header = audioHeader()
        #expect(GSCKValidateFrameHeader(&header))
    }

    @Test
    func validate_OddNV12Dimensions_RejectsHeader() {
        var header = videoHeader()
        header.pixelFormatFourCC = GEIST_SCK_PIXFMT_NV12_VIDEO
        header.height = 3
        header.bytesPerRowPlane1 = 8
        #expect(!GSCKValidateFrameHeader(&header))
    }

    private func videoHeader() -> geist_sck_frame_header_t {
        var header = geist_sck_frame_header_t()
        header.magic = GEIST_SCK_WIRE_MAGIC
        header.streamType = GEIST_SCK_STREAM_SCREEN
        header.pixelFormatFourCC = GEIST_SCK_PIXFMT_BGRA32
        header.width = 2
        header.height = 2
        header.bytesPerRowPlane0 = 8
        header.payloadSize = 16
        return header
    }

    private func audioHeader() -> geist_sck_frame_header_t {
        var header = geist_sck_frame_header_t()
        header.magic = GEIST_SCK_WIRE_MAGIC
        header.streamType = GEIST_SCK_STREAM_MICROPHONE
        header.audioSampleRate = 48000
        header.audioChannelCount = 2
        header.audioSampleCount = 4
        header.audioSampleFormat = GEIST_SCK_AUDIO_PCM_FLOAT32
        header.payloadSize = 32
        return header
    }
}
