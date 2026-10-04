import CoreMedia
import AVFoundation
import CoreVideo
import Foundation
import GeistScreenCaptureShimCore

struct ScreenCaptureFrameEncoder {
    func encodeMicrophone(_ buffer: AVAudioPCMBuffer, presentationTime: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) -> Data? {
        guard presentationTime.isNumeric, presentationTime >= .zero,
              buffer.frameLength > 0,
              buffer.format.sampleRate > 0, buffer.format.sampleRate <= Double(UInt32.max),
              let encoded = audioPayload(buffer)
        else { return nil }
        let header = audioHeader(buffer: buffer, encoded: encoded, presentationTime: presentationTime)
        var result = header.encode()
        result.append(encoded.data)
        return result
    }

    func encodeVideo(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) -> Data? {
        guard presentationTime.isNumeric, presentationTime >= .zero else { return nil }
        guard [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            .contains(CVPixelBufferGetPixelFormatType(pixelBuffer)) else { return nil }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let planes = planes(from: pixelBuffer) else { return nil }
        let header = videoHeader(pixelBuffer: pixelBuffer, planes: planes, presentationTime: presentationTime)
        var result = header.encode()
        result.append(planes.payload)
        return result
    }

    private func planes(from pixelBuffer: CVPixelBuffer) -> PixelPlanes? {
        if CVPixelBufferGetPlaneCount(pixelBuffer) == 0 {
            return packedPlane(from: pixelBuffer)
        }
        return planarPlanes(from: pixelBuffer)
    }

    private func packedPlane(from pixelBuffer: CVPixelBuffer) -> PixelPlanes? {
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let byteCount = bytesPerRow * CVPixelBufferGetHeight(pixelBuffer)
        return PixelPlanes(
            payload: Data(bytes: base, count: byteCount),
            bytesPerRowPlane0: UInt32(bytesPerRow),
            bytesPerRowPlane1: 0
        )
    }

    private func planarPlanes(from pixelBuffer: CVPixelBuffer) -> PixelPlanes? {
        guard let first = planeData(pixelBuffer, index: 0) else { return nil }
        let second = planeData(pixelBuffer, index: 1)
        var payload = first.data
        if let second { payload.append(second.data) }
        return PixelPlanes(
            payload: payload,
            bytesPerRowPlane0: UInt32(first.bytesPerRow),
            bytesPerRowPlane1: UInt32(second?.bytesPerRow ?? 0)
        )
    }

    private func planeData(_ pixelBuffer: CVPixelBuffer, index: Int) -> PlaneData? {
        guard index < CVPixelBufferGetPlaneCount(pixelBuffer),
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, index)
        else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, index)
        let byteCount = bytesPerRow * CVPixelBufferGetHeightOfPlane(pixelBuffer, index)
        return PlaneData(data: Data(bytes: base, count: byteCount), bytesPerRow: bytesPerRow)
    }

    private func videoHeader(pixelBuffer: CVPixelBuffer, planes: PixelPlanes, presentationTime: CMTime) -> FrameHeader {
        FrameHeader(
            streamType: GEIST_SCK_STREAM_SCREEN,
            pixelFormatFourCC: CVPixelBufferGetPixelFormatType(pixelBuffer),
            width: UInt32(CVPixelBufferGetWidth(pixelBuffer)),
            height: UInt32(CVPixelBufferGetHeight(pixelBuffer)),
            bytesPerRowPlane0: planes.bytesPerRowPlane0,
            bytesPerRowPlane1: planes.bytesPerRowPlane1,
            payloadSize: UInt32(planes.payload.count),
            presentationTime: presentationTime
        )
    }

    private func audioPayload(_ buffer: AVAudioPCMBuffer) -> EncodedAudio? {
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            return floatPayload(buffer)
        case .pcmFormatInt16:
            return int16Payload(buffer)
        default:
            return nil
        }
    }

    private func floatPayload(_ buffer: AVAudioPCMBuffer) -> EncodedAudio? {
        payload(buffer, bytesPerSample: MemoryLayout<Float>.size, format: GEIST_SCK_AUDIO_PCM_FLOAT32)
    }

    private func int16Payload(_ buffer: AVAudioPCMBuffer) -> EncodedAudio? {
        payload(buffer, bytesPerSample: MemoryLayout<Int16>.size, format: GEIST_SCK_AUDIO_PCM_INT16)
    }

    private func payload(_ buffer: AVAudioPCMBuffer, bytesPerSample: Int, format: UInt32) -> EncodedAudio? {
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let channels = Int(buffer.format.channelCount)
        guard channels > 0, buffers.count == (buffer.format.isInterleaved ? 1 : channels) else { return nil }
        var data = Data()
        for audioBuffer in buffers {
            let size = Int(buffer.frameLength) * bytesPerSample * Int(audioBuffer.mNumberChannels)
            guard let source = audioBuffer.mData, size <= Int(audioBuffer.mDataByteSize) else { return nil }
            data.append(Data(bytes: source, count: size))
        }
        return EncodedAudio(data: data, format: format)
    }

    private func audioHeader(buffer: AVAudioPCMBuffer, encoded: EncodedAudio, presentationTime: CMTime) -> FrameHeader {
        FrameHeader(
            streamType: GEIST_SCK_STREAM_MICROPHONE,
            audioSampleRate: UInt32(buffer.format.sampleRate),
            audioChannelCount: UInt32(buffer.format.channelCount),
            audioSampleFormat: encoded.format,
            audioInterleaved: buffer.format.isInterleaved ? 1 : 0,
            audioSampleCount: UInt32(buffer.frameLength),
            payloadSize: UInt32(encoded.data.count),
            presentationTime: presentationTime
        )
    }
}

private struct PixelPlanes {
    let payload: Data
    let bytesPerRowPlane0: UInt32
    let bytesPerRowPlane1: UInt32
}

private struct PlaneData {
    let data: Data
    let bytesPerRow: Int
}

private struct EncodedAudio {
    let data: Data
    let format: UInt32
}
