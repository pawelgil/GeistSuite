import Foundation

struct OutboundFrame: Sendable {
    private enum Policy: Sendable {
        case audio(slot: UInt32)
        case reliable
        case video(slot: UInt32)
    }

    private let policy: Policy
    let encoded: Data

    var byteCount: Int {
        encoded.count
    }

    var isReliable: Bool {
        switch policy {
        case .audio, .reliable: true
        case .video: false
        }
    }

    var videoSlot: UInt32? {
        guard case .video(let slot) = policy else { return nil }
        return slot
    }

    static func audio(slot: UInt32, payload: Data) -> OutboundFrame {
        OutboundFrame(policy: .audio(slot: slot), encoded: .framed(.audioFrame, payload: payload))
    }

    static func reliable(type: WireMessageType, payload: Data) -> OutboundFrame {
        OutboundFrame(policy: .reliable, encoded: .framed(type, payload: payload))
    }

    static func video(slot: UInt32, payload: Data) -> OutboundFrame {
        OutboundFrame(policy: .video(slot: slot), encoded: .framed(.videoFrame, payload: payload))
    }
}
