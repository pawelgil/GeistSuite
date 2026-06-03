import Foundation

// Swift mirror of camera-poc/shim/Wire.h. Layout & framing rules live there.

enum WireMessageType: UInt32 {
    case hello            = 1   // feeder → shim
    case helloAck         = 2   // shim → feeder
    case slotActive       = 3   // shim → feeder
    case videoFrame       = 4   // feeder → shim
    case audioFrame       = 5   // feeder → shim
    case demandUpdate     = 6   // shim → feeder
    case metadataResults  = 7   // feeder → shim
    case recordingState   = 8   // shim → feeder
    case activeFormat     = 9   // shim → feeder
}

enum WireMetaKind: UInt32 {
    case qr   = 0
    case face = 1
}

enum Wire {
    static let version: UInt32 = 1
    static let slotCount = 3
}

struct WireSlotInfo {
    var kind: UInt32           // 0=back, 1=front, 2=mic
    var width: UInt32
    var height: UInt32
    var pixelFormat: UInt32    // OSType (FourCC)
    var fpsNum: UInt32
    var fpsDen: UInt32
    var features: UInt32       // MediaSourceFeatures bitset
    var reserved: UInt32 = 0

    static let encodedSize = 32

    func encoded() -> Data {
        var d = Data(capacity: Self.encodedSize)
        d.appendLE(kind)
        d.appendLE(width)
        d.appendLE(height)
        d.appendLE(pixelFormat)
        d.appendLE(fpsNum)
        d.appendLE(fpsDen)
        d.appendLE(features)
        d.appendLE(reserved)
        return d
    }
}

struct WireHello {
    var slots: [WireSlotInfo]   // exactly Wire.slotCount entries; pad unused

    func encoded() -> Data {
        var d = Data(capacity: 8 + WireSlotInfo.encodedSize * Wire.slotCount)
        d.appendLE(Wire.version)
        d.appendLE(UInt32(slots.count))
        for s in slots { d.append(s.encoded()) }
        return d
    }
}

struct WireHelloAck {
    var version: UInt32
    var initialActive: [UInt32]   // length = Wire.slotCount

    static func decode(_ payload: Data) -> WireHelloAck? {
        guard payload.count == 4 + 4 * Wire.slotCount else { return nil }
        let version = payload.readLE(at: 0) as UInt32
        var active: [UInt32] = []
        for i in 0..<Wire.slotCount {
            active.append(payload.readLE(at: 4 + i * 4) as UInt32)
        }
        return WireHelloAck(version: version, initialActive: active)
    }
}

struct WireSlotActive {
    var slot: UInt32
    var active: UInt32

    static func decode(_ payload: Data) -> WireSlotActive? {
        guard payload.count == 8 else { return nil }
        return WireSlotActive(
            slot: payload.readLE(at: 0),
            active: payload.readLE(at: 4)
        )
    }
}

struct WireVideoFrameHeader {
    var slot: UInt32
    var width: UInt32
    var height: UInt32
    var pixelFormat: UInt32
    var ptsNs: Int64
    var durationNs: Int64
    var bytesLen: UInt32
    var reserved: UInt32 = 0

    func encoded() -> Data {
        var d = Data(capacity: 40)
        d.appendLE(slot)
        d.appendLE(width)
        d.appendLE(height)
        d.appendLE(pixelFormat)
        d.appendLE(UInt64(bitPattern: ptsNs))
        d.appendLE(UInt64(bitPattern: durationNs))
        d.appendLE(bytesLen)
        d.appendLE(reserved)
        return d
    }
}

struct WireAudioFrameHeader {
    var slot: UInt32
    var sampleCount: UInt32
    var sampleRate: UInt32
    var channels: UInt32
    var format: UInt32
    var bitsPerChannel: UInt32
    var ptsNs: Int64
    var bytesLen: UInt32
    var reserved: UInt32 = 0

    func encoded() -> Data {
        var d = Data(capacity: 40)
        d.appendLE(slot)
        d.appendLE(sampleCount)
        d.appendLE(sampleRate)
        d.appendLE(channels)
        d.appendLE(format)
        d.appendLE(bitsPerChannel)
        d.appendLE(UInt64(bitPattern: ptsNs))
        d.appendLE(bytesLen)
        d.appendLE(reserved)
        return d
    }
}

struct WireDemandUpdate {
    var slot: UInt32
    var wantsQR: UInt32
    var wantsFace: UInt32

    static func decode(_ payload: Data) -> WireDemandUpdate? {
        guard payload.count == 12 else { return nil }
        return WireDemandUpdate(
            slot: payload.readLE(at: 0),
            wantsQR: payload.readLE(at: 4),
            wantsFace: payload.readLE(at: 8)
        )
    }
}

struct WireRecordingState {
    var active: UInt32

    static func decode(_ payload: Data) -> WireRecordingState? {
        guard payload.count == 4 else { return nil }
        return WireRecordingState(active: payload.readLE(at: 0))
    }
}

struct WireActiveFormat {
    var slot: UInt32
    var width: UInt32
    var height: UInt32
    var pixelFormat: UInt32

    static func decode(_ payload: Data) -> WireActiveFormat? {
        guard payload.count == 16 else { return nil }
        return WireActiveFormat(
            slot: payload.readLE(at: 0),
            width: payload.readLE(at: 4),
            height: payload.readLE(at: 8),
            pixelFormat: payload.readLE(at: 12)
        )
    }
}

struct WireMetadataObject {
    var kind: WireMetaKind
    var faceID: Int32
    var boundsX: Float
    var boundsY: Float
    var boundsW: Float
    var boundsH: Float
    var stringValue: String?    // QR payload; nil/empty for face

    func encoded() -> Data {
        let utf8 = (stringValue ?? "").data(using: .utf8) ?? Data()
        var d = Data(capacity: 32 + utf8.count)
        d.appendLE(kind.rawValue)
        d.appendLE(UInt32(bitPattern: faceID))
        d.appendLE(boundsX.bitPattern)
        d.appendLE(boundsY.bitPattern)
        d.appendLE(boundsW.bitPattern)
        d.appendLE(boundsH.bitPattern)
        d.appendLE(UInt32(utf8.count))
        d.appendLE(UInt32(0))    // reserved
        d.append(utf8)
        return d
    }
}

struct WireMetadataResults {
    var slot: UInt32
    var objects: [WireMetadataObject]

    func encoded() -> Data {
        var d = Data(capacity: 8)
        d.appendLE(slot)
        d.appendLE(UInt32(objects.count))
        for o in objects { d.append(o.encoded()) }
        return d
    }
}

extension Data {
    static func framed(_ type: WireMessageType, payload: Data) -> Data {
        let length = UInt32(4 + payload.count)
        var out = Data(capacity: 8 + payload.count)
        out.appendLE(length)
        out.appendLE(type.rawValue)
        out.append(payload)
        return out
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    func readLE<T: FixedWidthInteger>(at offset: Int) -> T {
        precondition(offset + MemoryLayout<T>.size <= count, "read past end")
        return self.subdata(in: offset..<offset + MemoryLayout<T>.size)
            .withUnsafeBytes { $0.loadUnaligned(as: T.self) }
            .littleEndian
    }
}
