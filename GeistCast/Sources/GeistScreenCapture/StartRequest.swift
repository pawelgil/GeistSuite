import Foundation
import GeistScreenCaptureShimCore

struct CaptureOutputs: OptionSet {
    static let screen = CaptureOutputs(rawValue: GEIST_SCK_OUTPUT_SCREEN)
    static let audio = CaptureOutputs(rawValue: GEIST_SCK_OUTPUT_AUDIO)
    static let microphone = CaptureOutputs(rawValue: GEIST_SCK_OUTPUT_MICROPHONE)

    private static let known: CaptureOutputs = [.screen, .audio, .microphone]

    let rawValue: UInt32

    var containsOnlyKnownOutputs: Bool {
        rawValue & ~Self.known.rawValue == 0
    }
}

struct StartRequest {
    enum Error: Swift.Error, Equatable {
        case invalidRequest
        case notSupported
    }

    static let byteCount = MemoryLayout<geist_sck_start_request_t>.size

    let outputs: CaptureOutputs

    static func decode(_ data: Data) throws(Error) -> StartRequest {
        guard data.count >= byteCount else { throw .invalidRequest }
        let raw = data.withUnsafeBytes {
            $0.loadUnaligned(as: geist_sck_start_request_t.self)
        }
        guard raw.magic == GEIST_SCK_WIRE_MAGIC,
              raw.version == GEIST_SCK_WIRE_VERSION
        else { throw .invalidRequest }
        let outputs = CaptureOutputs(rawValue: raw.outputs)
        guard !outputs.isEmpty, outputs.containsOnlyKnownOutputs else { throw .invalidRequest }
        guard !outputs.contains(.audio) else { throw .notSupported }
        return StartRequest(outputs: outputs)
    }
}
