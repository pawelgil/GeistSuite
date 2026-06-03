import Foundation

/// @unchecked Sendable: `UserDefaults` is documented thread-safe but not
/// formally Sendable.
struct GlobalPreferences: @unchecked Sendable {
    private let defaults: UserDefaults
    private static let key = "geistcast.defaultMicSource"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var defaultMicSource: PersistableMicSource {
        get {
            guard let data = defaults.data(forKey: Self.key),
                  let decoded = try? JSONDecoder().decode(PersistableMicSource.self, from: data)
            else { return .systemMicrophone }
            return decoded
        }
        nonmutating set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.key)
            }
        }
    }
}
