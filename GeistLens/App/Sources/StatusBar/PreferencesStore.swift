import Foundation

final class PreferencesStore {
    static let shared = PreferencesStore()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func source(simulatorUDID: String, bundleID: String, side: CameraSide) -> PersistableSource? {
        let key = perAppKey(simulatorUDID: simulatorUDID, bundleID: bundleID, side: side)
        return decode(defaults.data(forKey: key))
    }

    func setSource(_ source: PersistableSource?, simulatorUDID: String, bundleID: String, side: CameraSide) {
        let key = perAppKey(simulatorUDID: simulatorUDID, bundleID: bundleID, side: side)
        if let source {
            defaults.set(encode(source), forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func perAppKey(simulatorUDID: String, bundleID: String, side: CameraSide) -> String {
        "geistlens.source.\(simulatorUDID).\(bundleID).\(side.rawValue)"
    }

    private func encode(_ source: PersistableSource) -> Data? {
        try? JSONEncoder().encode(source)
    }

    private func decode(_ data: Data?) -> PersistableSource? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(PersistableSource.self, from: data)
    }
}
