import Foundation

/// @unchecked Sendable: `UserDefaults` is documented thread-safe but not
/// formally Sendable.
struct GlobalPreferences: @unchecked Sendable {
    // MARK: Static Properties

    private static let defaultMicSourceKey = "geistcast.defaultMicSource"
    private static let screenCaptureKitSupportKey = "geistcast.screenCaptureKitSupport"

    // MARK: Properties

    private let defaults: UserDefaults

    // MARK: Computed Properties

    var defaultMicSource: PersistableMicSource {
        get {
            guard let data = defaults.data(forKey: Self.defaultMicSourceKey),
                  let decoded = try? JSONDecoder().decode(PersistableMicSource.self, from: data)
            else { return .systemMicrophone }
            return decoded
        }
        nonmutating set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.defaultMicSourceKey)
            }
        }
    }

    var screenCaptureKitSupportEnabled: Bool {
        get { defaults.bool(forKey: Self.screenCaptureKitSupportKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.screenCaptureKitSupportKey) }
    }

    // MARK: Lifecycle

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }
}
