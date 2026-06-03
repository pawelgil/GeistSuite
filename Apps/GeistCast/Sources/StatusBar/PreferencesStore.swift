import Foundation

/// `nil` source means "use the global default".
///
/// @unchecked Sendable: `UserDefaults` is documented thread-safe but not
/// formally Sendable.
struct PreferencesStore: @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func micSource(simulatorUDID: String, bundleID: String) -> PersistableMicSource? {
        guard let data = defaults.data(forKey: Self.key(simulatorUDID: simulatorUDID, bundleID: bundleID))
        else { return nil }
        return try? JSONDecoder().decode(PersistableMicSource.self, from: data)
    }

    func setMicSource(_ source: PersistableMicSource?,
                       simulatorUDID: String,
                       bundleID: String) {
        let key = Self.key(simulatorUDID: simulatorUDID, bundleID: bundleID)
        guard let source else {
            defaults.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(source) {
            defaults.set(data, forKey: key)
        }
    }

    private static func key(simulatorUDID: String, bundleID: String) -> String {
        "geistcast.micsource.\(simulatorUDID).\(bundleID)"
    }
}
