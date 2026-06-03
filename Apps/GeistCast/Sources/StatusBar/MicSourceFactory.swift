import Foundation
import GeistBroadcast

enum MicSourceFactory {
    static func make(_ source: PersistableMicSource) -> MicAudioConfig {
        switch source {
        case .systemMicrophone: return .systemMicrophone
        case .mediaFile(let path): return .mediaFile(URL(fileURLWithPath: path))
        case .disabled: return .disabled
        }
    }
}
