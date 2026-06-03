import Foundation
import GeistShimCore

enum StreamType: UInt32, Sendable {
    case video = 0x56
    case audioMic = 0x4D
    case audioApp = 0x41
}

enum AudioWireSampleFormat: UInt32, Sendable {
    case pcmInt16 = 0x01
    case pcmFloat32 = 0x02
}

struct FrameHeader: Equatable, Sendable {
    static let bgra32: UInt32 = 0x42475241
    static let nv12VideoRange: UInt32 = 0x34323076

    var streamType: UInt32
    var pixelFormatFourCC: UInt32
    var width: UInt32
    var height: UInt32
    var bytesPerRowPlane0: UInt32
    var bytesPerRowPlane1: UInt32
    var audioSampleRate: UInt32
    var audioChannelCount: UInt32
    var audioSampleFormat: UInt32
    var audioInterleaved: UInt32
    var audioSampleCount: UInt32
    var payloadSize: UInt32

    static let byteCount = 13 * MemoryLayout<UInt32>.size

    static func video(pixelFormatFourCC: UInt32,
                      width: UInt32,
                      height: UInt32,
                      bytesPerRowPlane0: UInt32,
                      bytesPerRowPlane1: UInt32,
                      payloadSize: UInt32) -> FrameHeader {
        FrameHeader(
            streamType: StreamType.video.rawValue,
            pixelFormatFourCC: pixelFormatFourCC,
            width: width,
            height: height,
            bytesPerRowPlane0: bytesPerRowPlane0,
            bytesPerRowPlane1: bytesPerRowPlane1,
            audioSampleRate: 0,
            audioChannelCount: 0,
            audioSampleFormat: 0,
            audioInterleaved: 0,
            audioSampleCount: 0,
            payloadSize: payloadSize
        )
    }

    static func audio(stream: StreamType,
                      sampleRate: UInt32,
                      channelCount: UInt32,
                      sampleFormat: AudioWireSampleFormat,
                      isInterleaved: Bool,
                      sampleCount: UInt32,
                      payloadSize: UInt32) -> FrameHeader {
        FrameHeader(
            streamType: stream.rawValue,
            pixelFormatFourCC: 0,
            width: 0,
            height: 0,
            bytesPerRowPlane0: 0,
            bytesPerRowPlane1: 0,
            audioSampleRate: sampleRate,
            audioChannelCount: channelCount,
            audioSampleFormat: sampleFormat.rawValue,
            audioInterleaved: isInterleaved ? 1 : 0,
            audioSampleCount: sampleCount,
            payloadSize: payloadSize
        )
    }

    func encoded() -> Data {
        var data = Data(count: Self.byteCount)
        data.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt32.self).baseAddress!
            p[0] = GEISTCAST_WIRE_MAGIC
            p[1] = streamType
            p[2] = pixelFormatFourCC
            p[3] = width
            p[4] = height
            p[5] = bytesPerRowPlane0
            p[6] = bytesPerRowPlane1
            p[7] = audioSampleRate
            p[8] = audioChannelCount
            p[9] = audioSampleFormat
            p[10] = audioInterleaved
            p[11] = audioSampleCount
            p[12] = payloadSize
        }
        return data
    }

    static func decoded(from data: Data) -> FrameHeader? {
        guard data.count >= byteCount else { return nil }
        return data.withUnsafeBytes { raw -> FrameHeader? in
            let p = raw.bindMemory(to: UInt32.self).baseAddress!
            guard p[0] == GEISTCAST_WIRE_MAGIC else { return nil }
            return FrameHeader(
                streamType: p[1],
                pixelFormatFourCC: p[2],
                width: p[3],
                height: p[4],
                bytesPerRowPlane0: p[5],
                bytesPerRowPlane1: p[6],
                audioSampleRate: p[7],
                audioChannelCount: p[8],
                audioSampleFormat: p[9],
                audioInterleaved: p[10],
                audioSampleCount: p[11],
                payloadSize: p[12]
            )
        }
    }
}

enum WireMessage: Equatable, Sendable {
    case broadcastStarted(Broadcast)
    case broadcastEnded(Broadcast)
    case helloHost
    case helloExtension(extensionBundleID: String)
    case state(recording: Bool, broadcast: Broadcast?, micEnabled: Bool, macOSMicAuthorized: Bool)
    case userPressedStart(micEnabled: Bool)
    case userCancelledStart
    case userPressedStop
    case begin(Broadcast)
    case finish
    case pause
    case resume
    case extensionTerminated(errorDomain: String, errorCode: Int, errorMessage: String)
    case setMicAudioReadiness(ready: Bool)
    case userToggledMic(enabled: Bool)
}

struct WireDecoder {

    private var buffer = Data()
    private let isoFormatter = ISO8601DateFormatter()

    init() {}

    mutating func feed(_ chunk: Data) -> [WireMessage] {
        buffer.append(chunk)
        var messages: [WireMessage] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if let message = decodeLine(line) { messages.append(message) }
        }
        return messages
    }

    private func decodeLine(_ line: Data) -> WireMessage? {
        guard
            let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = json["type"] as? String
        else { return nil }

        switch type {
        case "started":
            return extractBroadcast(json).map(WireMessage.broadcastStarted)
        case "ended":
            return extractBroadcast(json).map(WireMessage.broadcastEnded)
        case "hello":
            return decodeHello(json)
        case "state":
            return decodeState(json)
        case "user_pressed_start":
            let micEnabled = json["micEnabled"] as? Bool ?? false
            return .userPressedStart(micEnabled: micEnabled)
        case "user_cancelled_start":
            return .userCancelledStart
        case "user_pressed_stop":
            return .userPressedStop
        case "begin":
            return extractBroadcast(json).map(WireMessage.begin)
        case "finish":
            return .finish
        case "pause":
            return .pause
        case "resume":
            return .resume
        case "extension_terminated":
            return decodeExtensionTerminated(json)
        case "set_mic_audio_readiness":
            guard let ready = json["ready"] as? Bool else { return nil }
            return .setMicAudioReadiness(ready: ready)
        case "user_toggled_mic":
            guard let enabled = json["enabled"] as? Bool else { return nil }
            return .userToggledMic(enabled: enabled)
        default:
            return nil
        }
    }

    private func decodeExtensionTerminated(_ json: [String: Any]) -> WireMessage? {
        let domain = json["errorDomain"] as? String ?? ""
        let code = (json["errorCode"] as? NSNumber)?.intValue ?? 0
        let message = json["errorMessage"] as? String ?? ""
        return .extensionTerminated(errorDomain: domain, errorCode: code, errorMessage: message)
    }

    private func decodeHello(_ json: [String: Any]) -> WireMessage? {
        guard let role = json["role"] as? String else { return nil }
        switch role {
        case "host":
            return .helloHost
        case "extension":
            guard let bundleID = json["extensionBundleID"] as? String else { return nil }
            return .helloExtension(extensionBundleID: bundleID)
        default:
            return nil
        }
    }

    private func decodeState(_ json: [String: Any]) -> WireMessage? {
        guard let recording = json["recording"] as? Bool else { return nil }
        let micEnabled = json["micEnabled"] as? Bool ?? false
        let macOSMicAuthorized = json["macOSMicAuthorized"] as? Bool ?? true
        return .state(
            recording: recording,
            broadcast: recording ? extractBroadcast(json) : nil,
            micEnabled: micEnabled,
            macOSMicAuthorized: macOSMicAuthorized
        )
    }

    private func extractBroadcast(_ json: [String: Any]) -> Broadcast? {
        guard
            let sim = json["simulatorUDID"] as? String,
            let host = json["hostAppBundleID"] as? String,
            let ext = json["extensionBundleID"] as? String,
            let startedAtString = json["startedAt"] as? String,
            let startedAt = isoFormatter.date(from: startedAtString)
        else { return nil }
        return Broadcast(
            simulatorUDID: sim,
            hostAppBundleID: host,
            extensionBundleID: ext,
            startedAt: startedAt
        )
    }
}

struct WireEncoder {

    private let isoFormatter = ISO8601DateFormatter()

    init() {}

    func encode(_ message: WireMessage) -> Data {
        let object = jsonObject(for: message)
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }

    private func jsonObject(for message: WireMessage) -> [String: Any] {
        switch message {
        case .broadcastStarted(let b):
            return broadcastObject(b, type: "started")
        case .broadcastEnded(let b):
            return broadcastObject(b, type: "ended")
        case .helloHost:
            return ["type": "hello", "role": "host"]
        case .helloExtension(let bundleID):
            return ["type": "hello", "role": "extension", "extensionBundleID": bundleID]
        case .state(let recording, let broadcast, let micEnabled, let macOSMicAuthorized):
            var obj: [String: Any] = [
                "type": "state",
                "recording": recording,
                "macOSMicAuthorized": macOSMicAuthorized,
            ]
            if recording, let b = broadcast {
                obj["simulatorUDID"] = b.simulatorUDID
                obj["hostAppBundleID"] = b.hostAppBundleID
                obj["extensionBundleID"] = b.extensionBundleID
                obj["startedAt"] = isoFormatter.string(from: b.startedAt)
                obj["micEnabled"] = micEnabled
            }
            return obj
        case .userPressedStart(let micEnabled):
            return ["type": "user_pressed_start", "micEnabled": micEnabled]
        case .userCancelledStart:
            return ["type": "user_cancelled_start"]
        case .userPressedStop:
            return ["type": "user_pressed_stop"]
        case .begin(let b):
            return broadcastObject(b, type: "begin")
        case .finish:
            return ["type": "finish"]
        case .pause:
            return ["type": "pause"]
        case .resume:
            return ["type": "resume"]
        case .extensionTerminated(let domain, let code, let message):
            return [
                "type": "extension_terminated",
                "errorDomain": domain,
                "errorCode": code,
                "errorMessage": message,
            ]
        case .setMicAudioReadiness(let ready):
            return ["type": "set_mic_audio_readiness", "ready": ready]
        case .userToggledMic(let enabled):
            return ["type": "user_toggled_mic", "enabled": enabled]
        }
    }

    private func broadcastObject(_ b: Broadcast, type: String) -> [String: Any] {
        [
            "type": type,
            "simulatorUDID": b.simulatorUDID,
            "hostAppBundleID": b.hostAppBundleID,
            "extensionBundleID": b.extensionBundleID,
            "startedAt": isoFormatter.string(from: b.startedAt),
        ]
    }
}
