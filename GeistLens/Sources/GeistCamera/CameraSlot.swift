import AVFoundation

// (DeviceType, Position) lets additional cameras slot in later. v1 mints
// only the three statics below; other combinations throw slotNotSupported.
public enum CameraSlot: Hashable, Sendable {
    case camera(AVCaptureDevice.DeviceType, AVCaptureDevice.Position)
    case microphone

    public static let backCamera: Self = .camera(.builtInWideAngleCamera, .back)
    public static let frontCamera: Self = .camera(.builtInWideAngleCamera, .front)
}

extension CameraSlot {
    // Mirrors GeistCamSlot in Wire.h.
    var wireIndex: UInt32? {
        switch self {
        case .backCamera:  return 0
        case .frontCamera: return 1
        case .microphone:  return 2
        default:           return nil
        }
    }

    var debugLabel: String {
        switch self {
        case .backCamera:  return "backCamera"
        case .frontCamera: return "frontCamera"
        case .microphone:  return "microphone"
        case .camera(let type, let pos):
            return "camera(\(type.rawValue), pos=\(pos.rawValue))"
        }
    }
}
