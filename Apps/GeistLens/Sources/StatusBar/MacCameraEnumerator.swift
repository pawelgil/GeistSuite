import AVFoundation
import Foundation

struct MacCamera {
    let uniqueID: String
    let localizedName: String
}

enum MacCameraEnumerator {
    static func devices() -> [MacCamera] {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera,
        ]
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified
        )
        return session.devices.map { MacCamera(uniqueID: $0.uniqueID, localizedName: $0.localizedName) }
    }
}
