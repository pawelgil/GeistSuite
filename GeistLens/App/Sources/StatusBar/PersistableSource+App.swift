import Foundation
import GeistCamera

extension PersistableSource {
    var isUsable: Bool {
        switch self {
        case .macOSCamera(let uid):
            return Permissions.cameraAuthorized
                && MacCameraEnumerator.devices().contains(where: { $0.uniqueID == uid })
        case .video(let path), .image(let path):
            return FileManager.default.fileExists(atPath: path)
        }
    }

    var displayLabel: String {
        switch self {
        case .macOSCamera(let uid):
            if let device = MacCameraEnumerator.devices().first(where: { $0.uniqueID == uid }) {
                return device.localizedName
            }
            return "macOS Camera"
        case .video(let path):
            return "Video: \((path as NSString).lastPathComponent)"
        case .image(let path):
            return "Image: \((path as NSString).lastPathComponent)"
        }
    }
}

extension CameraSide {
    var simCameraSlot: CameraSlot {
        switch self {
        case .front: return .frontCamera
        case .back: return .backCamera
        }
    }
}
