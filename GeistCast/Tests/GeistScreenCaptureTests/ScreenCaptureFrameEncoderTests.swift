import AVFoundation
import CoreVideo
@testable import GeistScreenCapture
import GeistScreenCaptureShimCore
import Testing

struct ScreenCaptureFrameEncoderTests {
    @Test
    func encodeVideo_BGRAFrame_PreservesDimensionsAndPayload() throws {
        let pixelBuffer = try makePixelBuffer(width: 2, height: 2)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let payloadSize = CVPixelBufferGetBytesPerRow(pixelBuffer)
            * CVPixelBufferGetHeight(pixelBuffer)
        CVPixelBufferGetBaseAddress(pixelBuffer)?
            .initializeMemory(as: UInt8.self, repeating: 0x5A, count: payloadSize)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        let sut = ScreenCaptureFrameEncoder()

        let data = try #require(sut.encodeVideo(pixelBuffer))

        let header = try #require(FrameHeader.decode(data))
        #expect(header.streamType == GEIST_SCK_STREAM_SCREEN)
        #expect(header.pixelFormatFourCC == GEIST_SCK_PIXFMT_BGRA32)
        #expect(header.width == 2)
        #expect(header.height == 2)
        #expect(data.count == FrameHeader.byteCount + Int(header.payloadSize))
        #expect(data.dropFirst(FrameHeader.byteCount) == Data(repeating: 0x5A, count: payloadSize))
    }

    @Test
    func encodeMicrophone_FloatPCM_PreservesAudioFormat() throws {
        let buffer = try makeAudioBuffer(sampleRate: 48000, channels: 1, frames: 16)
        for index in 0 ..< 16 {
            buffer.floatChannelData?[0][index] = Float(index) / 16
        }
        let sut = ScreenCaptureFrameEncoder()

        let data = try #require(sut.encodeMicrophone(buffer))

        let header = try #require(FrameHeader.decode(data))
        #expect(header.streamType == GEIST_SCK_STREAM_MICROPHONE)
        #expect(header.audioSampleRate == 48000)
        #expect(header.audioChannelCount == 1)
        #expect(header.audioSampleFormat == GEIST_SCK_AUDIO_PCM_FLOAT32)
        #expect(header.audioInterleaved == 0)
        #expect(header.audioSampleCount == 16)
        let samples = data.dropFirst(FrameHeader.byteCount).withUnsafeBytes {
            Array($0.bindMemory(to: Float.self))
        }
        #expect(samples == (0 ..< 16).map { Float($0) / 16 })
    }

    @Test
    func encodeMicrophone_Int16PCM_PreservesSamples() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let expected: [Int16] = [-200, -1, 1, 200]
        for (index, sample) in expected.enumerated() {
            buffer.int16ChannelData?[0][index] = sample
        }
        let sut = ScreenCaptureFrameEncoder()

        let data = try #require(sut.encodeMicrophone(buffer))

        let header = try #require(FrameHeader.decode(data))
        #expect(header.audioSampleFormat == GEIST_SCK_AUDIO_PCM_INT16)
        let samples = data.dropFirst(FrameHeader.byteCount).withUnsafeBytes {
            Array($0.bindMemory(to: Int16.self))
        }
        #expect(samples == expected)
    }

    @Test(arguments: [true, false])
    func encodeMicrophone_StereoPCM_PreservesChannelLayout(interleaved: Bool) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 48000, channels: 2, interleaved: interleaved))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        buffer.frameLength = 2
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let expected: [Float] = interleaved ? [1, 3, 2, 4] : [1, 2, 3, 4]
        var offset = 0
        for audio in buffers {
            let samples = try #require(audio.mData).assumingMemoryBound(to: Float.self)
            for index in 0..<Int(audio.mDataByteSize) / 4 {
                samples[index] = expected[offset]
                offset += 1
            }
        }

        let data = try #require(ScreenCaptureFrameEncoder().encodeMicrophone(buffer))

        let header = try #require(FrameHeader.decode(data))
        #expect(header.audioInterleaved == (interleaved ? 1 : 0))
        #expect(header.audioChannelCount == 2)
        let payload = data.dropFirst(FrameHeader.byteCount)
        let samples = stride(from: 0, to: payload.count, by: 4).map { offset in
            payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) }
        }
        #expect(samples == expected)
    }

    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        return try #require(pixelBuffer)
    }

    private func makeAudioBuffer(
        sampleRate: Double,
        channels: AVAudioChannelCount,
        frames: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        return buffer
    }
}
