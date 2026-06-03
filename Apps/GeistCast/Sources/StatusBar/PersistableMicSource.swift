import Foundation

/// `MicAudioConfig.custom` is intentionally absent — custom producers are
/// runtime objects, not user-pickable.
enum PersistableMicSource: Codable, Equatable, Sendable {
    case systemMicrophone
    case mediaFile(path: String)
    case disabled
}
