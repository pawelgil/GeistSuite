import Foundation
import Geist

enum MicSourceFactory {
    static func make(_ source: PersistableMicSource) -> MicSource {
        switch source {
        case .systemMicrophone: return .systemMicrophone
        case .mediaFile(let path): return .mediaFile(URL(fileURLWithPath: path))
        case .disabled: return .disabled
        }
    }
}
