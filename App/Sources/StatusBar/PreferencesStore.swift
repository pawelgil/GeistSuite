import Foundation

final class PreferencesStore {
    static let shared = PreferencesStore()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func source(simulatorUDID: String, bundleID: String, side: CameraSide) -> PersistableSource? {
        let key = perAppCameraKey(simulatorUDID: simulatorUDID, bundleID: bundleID, side: side)
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistableSource.self, from: data)
    }

    func setSource(_ source: PersistableSource?, simulatorUDID: String, bundleID: String, side: CameraSide) {
        let key = perAppCameraKey(simulatorUDID: simulatorUDID, bundleID: bundleID, side: side)
        if let source, let data = try? JSONEncoder().encode(source) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func micSource(simulatorUDID: String, bundleID: String) -> PersistableMicSource? {
        let key = perAppMicKey(simulatorUDID: simulatorUDID, bundleID: bundleID)
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistableMicSource.self, from: data)
    }

    func setMicSource(_ source: PersistableMicSource?, simulatorUDID: String, bundleID: String) {
        let key = perAppMicKey(simulatorUDID: simulatorUDID, bundleID: bundleID)
        if let source, let data = try? JSONEncoder().encode(source) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func perAppCameraKey(simulatorUDID: String, bundleID: String, side: CameraSide) -> String {
        "geistlens.source.\(simulatorUDID).\(bundleID).\(side.rawValue)"
    }

    private func perAppMicKey(simulatorUDID: String, bundleID: String) -> String {
        "geistlens.micsource.\(simulatorUDID).\(bundleID)"
    }
}
