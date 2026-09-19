import AudioToolbox
import CoreMedia
import CoreVideo
import GeistCameraShimCore
import Testing

struct SampleRetimingTests {
    // MARK: Nested Types

    struct AudioCase: CustomTestStringConvertible {
        // MARK: Properties

        let frameCount: Int
        let sampleRate: Int32

        // MARK: Computed Properties

        var testDescription: String {
            "\(frameCount)frames-\(sampleRate)Hz"
        }
    }

    // MARK: Static Properties

    static let audioCases = [
        AudioCase(frameCount: 4800, sampleRate: 48000),
        AudioCase(frameCount: 557, sampleRate: 48000),
        AudioCase(frameCount: 558, sampleRate: 48000),
        AudioCase(frameCount: 1, sampleRate: 8000),
        AudioCase(frameCount: 557, sampleRate: 44100),
        AudioCase(frameCount: 558, sampleRate: 96000),
    ]

    // MARK: Functions

    @Test(arguments: audioCases)
    func CopyRetimedUniformSampleBuffer_UniformAudio_PreservesSamplesAndChangesOnlyPTS(
        audioCase: AudioCase
    ) throws {
        let sourcePTS = CMTime(value: 1337, timescale: audioCase.sampleRate)
        let newPTS = CMTime(value: 9001, timescale: 600)
        let source = try makeAudioBuffer(
            frameCount: audioCase.frameCount,
            sampleRate: audioCase.sampleRate,
            presentationTime: sourcePTS
        )
        let sourceBytes = try dataBytes(source)
        let sourceDuration = CMSampleBufferGetDuration(source)
        let sourceTiming = try timing(source)

        let result = try #require(GeistCamCopyRetimedUniformSampleBuffer(source, newPTS))

        let resultTiming = try timing(result)
        #expect(CMSampleBufferGetNumSamples(result) == audioCase.frameCount)
        #expect(try dataBytes(result) == sourceBytes)
        #expect(CMTimeCompare(resultTiming.presentationTimeStamp, newPTS) == 0)
        #expect(CMTimeCompare(resultTiming.duration, sourceTiming.duration) == 0)
        #expect(CMTimeCompare(resultTiming.duration, CMTime(value: 1, timescale: audioCase.sampleRate)) == 0)
        #expect(CMTimeCompare(CMSampleBufferGetDuration(result), sourceDuration) == 0)
        #expect(CMTimeCompare(
            CMSampleBufferGetDuration(result),
            CMTime(value: CMTimeValue(audioCase.frameCount), timescale: audioCase.sampleRate)
        ) == 0)
        #expect(!resultTiming.decodeTimeStamp.isValid)

        let unchangedTiming = try timing(source)
        #expect(CMTimeCompare(unchangedTiming.presentationTimeStamp, sourcePTS) == 0)
        #expect(CMTimeCompare(unchangedTiming.duration, sourceTiming.duration) == 0)
        #expect(try dataBytes(source) == sourceBytes)
    }

    @Test
    func CopyRetimedUniformSampleBuffer_OneSampleVideo_PreservesImageAndDuration() throws {
        let source = try makeVideoBuffer()
        let sourceImage = try #require(CMSampleBufferGetImageBuffer(source))
        let sourceDuration = CMSampleBufferGetDuration(source)
        let newPTS = CMTime(value: 42, timescale: 30)

        let result = try #require(GeistCamCopyRetimedUniformSampleBuffer(source, newPTS))

        let resultImage = try #require(CMSampleBufferGetImageBuffer(result))
        let resultTiming = try timing(result)
        #expect(sourceImage === resultImage)
        #expect(CMSampleBufferGetNumSamples(result) == 1)
        #expect(CMTimeCompare(resultTiming.presentationTimeStamp, newPTS) == 0)
        #expect(CMTimeCompare(resultTiming.duration, CMTime(value: 1, timescale: 30)) == 0)
        #expect(CMTimeCompare(CMSampleBufferGetDuration(result), sourceDuration) == 0)
        #expect(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(source), CMTime(value: 10, timescale: 30)) == 0)
    }

    @Test
    func CopyRetimedUniformSampleBuffer_NullSource_RejectsInput() {
        #expect(GeistCamCopyRetimedUniformSampleBuffer(nil, .zero) == nil)
    }

    @Test(arguments: [CMTime.invalid, CMTime.indefinite, CMTime.positiveInfinity, CMTime.negativeInfinity])
    func CopyRetimedUniformSampleBuffer_NonnumericPTS_RejectsInput(presentationTime: CMTime) throws {
        let source = try makeAudioBuffer(frameCount: 1, sampleRate: 48000, presentationTime: .zero)

        #expect(GeistCamCopyRetimedUniformSampleBuffer(source, presentationTime) == nil)
    }

    @Test
    func CopyRetimedUniformSampleBuffer_MultipleTimingEntries_RejectsInput() throws {
        let source = try makeMultipleTimingBuffer()
        var timingCount = 0
        #expect(CMSampleBufferGetSampleTimingInfoArray(
            source,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &timingCount
        ) == noErr)
        #expect(timingCount == 2)

        #expect(GeistCamCopyRetimedUniformSampleBuffer(source, CMTime(value: 1, timescale: 1)) == nil)
    }

    private func makeAudioBuffer(
        frameCount: Int,
        sampleRate: Int32,
        presentationTime: CMTime
    ) throws -> CMSampleBuffer {
        let byteCount = frameCount * MemoryLayout<Float>.size
        let blockBuffer = try makeBlockBuffer(byteCount: byteCount)
        let bytes = (0 ..< byteCount).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
        #expect(CMBlockBufferReplaceDataBytes(
            with: bytes,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount
        ) == noErr)
        let format = try makeAudioFormat(sampleRate: sampleRate)
        var sampleBuffer: CMSampleBuffer?
        #expect(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: frameCount,
            presentationTimeStamp: presentationTime,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr)
        return try #require(sampleBuffer)
    }

    private func makeMultipleTimingBuffer() throws -> CMSampleBuffer {
        let blockBuffer = try makeBlockBuffer(byteCount: 2 * MemoryLayout<Float>.size)
        let format = try makeAudioFormat(sampleRate: 48000)
        var timings = [
            CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: 48000),
                presentationTimeStamp: .zero,
                decodeTimeStamp: .invalid
            ),
            CMSampleTimingInfo(
                duration: CMTime(value: 2, timescale: 48000),
                presentationTimeStamp: CMTime(value: 1, timescale: 48000),
                decodeTimeStamp: .invalid
            ),
        ]
        var sampleSizes = [MemoryLayout<Float>.size, MemoryLayout<Float>.size]
        var sampleBuffer: CMSampleBuffer?
        #expect(CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 2,
            sampleTimingEntryCount: timings.count,
            sampleTimingArray: &timings,
            sampleSizeEntryCount: sampleSizes.count,
            sampleSizeArray: &sampleSizes,
            sampleBufferOut: &sampleBuffer
        ) == noErr)
        return try #require(sampleBuffer)
    }

    private func makeAudioFormat(sampleRate: Int32) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        ) == noErr)
        return try #require(format)
    }

    private func makeBlockBuffer(byteCount: Int) throws -> CMBlockBuffer {
        var blockBuffer: CMBlockBuffer?
        #expect(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr)
        return try #require(blockBuffer)
    }

    private func makeVideoBuffer() throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(
            kCFAllocatorDefault,
            1,
            1,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        ) == kCVReturnSuccess)
        let imageBuffer = try #require(pixelBuffer)
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescriptionOut: &format
        ) == noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: 10, timescale: 30),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        #expect(try CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescription: #require(format),
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr)
        return try #require(sampleBuffer)
    }

    private func timing(_ buffer: CMSampleBuffer) throws -> CMSampleTimingInfo {
        var result = CMSampleTimingInfo()
        #expect(CMSampleBufferGetSampleTimingInfo(buffer, at: 0, timingInfoOut: &result) == noErr)
        return result
    }

    private func dataBytes(_ buffer: CMSampleBuffer) throws -> [UInt8] {
        let blockBuffer = try #require(CMSampleBufferGetDataBuffer(buffer))
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var bytes = [UInt8](repeating: 0, count: length)
        #expect(CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &bytes) == noErr)
        return bytes
    }
}
