import AudioToolbox
import AVFoundation
import GeistCameraShimCore
import Testing

struct AudioInputBufferTests {
    @Test func render_EmptyInput_ReplacesHostSamplesWithSilence() throws {
        let sut = try createSUT()
        defer { geistAudioInputBufferDestroy(sut) }

        let result = render(sut, frames: 4)

        #expect(result == [0, 0, 0, 0])
    }

    @Test func render_InjectedInput_PreservesSamples() throws {
        let sut = try createSUT()
        defer { geistAudioInputBufferDestroy(sut) }
        let samples: [Float] = [0.25, -0.5, 0.75, 0]
        #expect(geistAudioInputBufferAppend(sut, samples, samples.count, 1, 48000))

        let result = render(sut, frames: 4)

        #expect(result == [8192, -16384, 24576, 0])
    }

    @Test func render_Downsampling_PreservesDuration() throws {
        let sut = try createSUT(sampleRate: 24000)
        defer { geistAudioInputBufferDestroy(sut) }
        let samples: [Float] = [0.25, 0.5, 0.75, 0.5, 0.25, 0]
        #expect(geistAudioInputBufferAppend(sut, samples, samples.count, 1, 48000))

        #expect(render(sut, frames: 4) == [8192, 24576, 8192, 0])
    }

    @Test func render_StereoInput_DownmixesToMono() throws {
        let sut = try createSUT()
        defer { geistAudioInputBufferDestroy(sut) }
        let samples: [Float] = [0.25, 0.75, -0.5, 0.5, 0, 0]
        #expect(geistAudioInputBufferAppend(sut, samples, 3, 2, 48000))

        #expect(render(sut, frames: 2) == [16384, 0])
    }

    @Test func append_ExcessInput_RemainsBounded() throws {
        let sut = try createSUT(capacity: 2)
        defer { geistAudioInputBufferDestroy(sut) }
        let samples: [Float] = [0.25, 0.5, 0.75, 1]
        #expect(!geistAudioInputBufferAppend(sut, samples, samples.count, 1, 48000))

        #expect(render(sut, frames: 4) == [8192, 16384, 0, 0])
    }

    @Test func append_PacketBoundary_DoesNotLoseSamples() throws {
        let sut = try createSUT()
        defer { geistAudioInputBufferDestroy(sut) }
        append(sut, samples: [0.25, 0.5])
        append(sut, samples: [0.75, 0])

        #expect(render(sut, frames: 4) == [8192, 16384, 24576, 0])
    }

    @Test func discard_PreviousCapture_DoesNotReplaySamples() throws {
        let sut = try createSUT()
        defer { geistAudioInputBufferDestroy(sut) }
        append(sut, samples: [0.25, 0.5])

        geistAudioInputBufferRequestDiscard(sut)

        #expect(render(sut, frames: 4) == [0, 0, 0, 0])
    }

    @Test func reset_FullBuffer_AcceptsFreshCaptureImmediately() throws {
        let sut = try createSUT(capacity: 2)
        defer { geistAudioInputBufferDestroy(sut) }
        append(sut, samples: [0.25, 0.5, 0])
        geistAudioInputBufferReset(sut)

        append(sut, samples: [-0.25, -0.5, 0])

        #expect(render(sut, frames: 2) == [-8192, -16384])
    }

    @Test func render_Upsampling_InterpolatesAcrossPackets() throws {
        let sut = try createSUT(sampleRate: 48000)
        defer { geistAudioInputBufferDestroy(sut) }
        append(sut, samples: [0, 0.5], sampleRate: 24000)
        append(sut, samples: [1], sampleRate: 24000)

        #expect(render(sut, frames: 4) == [0, 8192, 16384, 24576])
    }

    @Test func append_InvalidRate_RejectsInput() throws {
        let sut = try createSUT()
        defer { geistAudioInputBufferDestroy(sut) }

        let samples: [Float] = [1, 1]
        #expect(!geistAudioInputBufferAppend(sut, samples, 2, 1, .nan))
        #expect(render(sut, frames: 2) == [0, 0])
    }

    @Test func render_NullFlags_StillReplacesHostSamples() throws {
        let sut = try createSUT()
        defer { geistAudioInputBufferDestroy(sut) }
        append(sut, samples: [0.5, 0])
        var sample: Int16 = 1234

        let status = withUnsafeMutablePointer(to: &sample) { pointer in
            var output = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: 2, mData: pointer
            ))
            return geistAudioInputBufferRender(sut, &output, 1, nil)
        }

        #expect(status == noErr)
        #expect(sample == 16384)
    }

    @Test(arguments: [true, false])
    func render_FloatStereo_PreservesChannelOrder(interleaved: Bool) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                                channels: 2, interleaved: interleaved))
        let sut = try #require(geistAudioInputBufferCreate(format.streamDescription.pointee, 32))
        defer { geistAudioInputBufferDestroy(sut) }
        let input: [Float] = [0.25, -0.5, 0.75, -0.25, 0, 0]
        #expect(geistAudioInputBufferAppend(sut, input, 3, 2, 48000))
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        output.frameLength = 3
        var flags: AudioUnitRenderActionFlags = .unitRenderAction_OutputIsSilence

        let status = geistAudioInputBufferRender(sut, output.mutableAudioBufferList, 3, &flags)

        #expect(status == noErr)
        #expect(floatChannel(output, channel: 0) == [0.25, 0.75, 0])
        #expect(floatChannel(output, channel: 1) == [-0.5, -0.25, 0])
        #expect(!flags.contains(.unitRenderAction_OutputIsSilence))
        #expect(UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList).map(\.mDataByteSize) ==
            (interleaved ? [24] : [12, 12]))
    }

    private func floatChannel(_ buffer: AVAudioPCMBuffer, channel: Int) -> [Float] {
        guard let channels = buffer.floatChannelData else { return [] }
        let samples = buffer.format.isInterleaved ? channels[0].advanced(by: channel) : channels[channel]
        return (0 ..< Int(buffer.frameLength)).map { samples[$0 * buffer.stride] }
    }

    private func createSUT(sampleRate: Double = 48000, capacity: Int = 32) throws -> OpaquePointer {
        let format = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        return try #require(geistAudioInputBufferCreate(format, capacity))
    }

    private func append(_ sut: OpaquePointer, samples: [Float], sampleRate: Double = 48000) {
        let admitted = samples.withUnsafeBufferPointer {
            geistAudioInputBufferAppend(sut, $0.baseAddress, $0.count, 1, sampleRate)
        }
        #expect(admitted)
    }

    private func render(_ sut: OpaquePointer, frames: Int) -> [Int16] {
        var samples = [Int16](repeating: 1234, count: frames)
        samples.withUnsafeMutableBytes { bytes in
            var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress
            ))
            var flags: AudioUnitRenderActionFlags = []
            #expect(geistAudioInputBufferRender(sut, &buffers, UInt32(frames), &flags) == noErr)
        }
        return samples
    }
}
