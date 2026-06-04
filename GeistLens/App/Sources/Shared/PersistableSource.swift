import Foundation

enum PersistableSource: Codable, Equatable, Sendable {
    case macOSCamera(deviceUID: String)
    case video(path: String)
    case image(path: String)
}

enum CameraSide: String, Codable, CaseIterable, Sendable {
    case back
    case front

    var displayName: String {
        switch self {
        case .front: return "Front"
        case .back:  return "Back"
        }
    }
}
