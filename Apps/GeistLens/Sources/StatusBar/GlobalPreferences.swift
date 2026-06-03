import Foundation
import ServiceManagement
import GeistCamera

@MainActor
final class GlobalPreferences {
    static let shared = GlobalPreferences()

    private let defaults: UserDefaults
    private let defaultSourceKey = "geistlens.defaultSource"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var defaultSource: PersistableSource? {
        get {
            guard let data = defaults.data(forKey: defaultSourceKey) else { return nil }
            return try? JSONDecoder().decode(PersistableSource.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: defaultSourceKey)
            } else {
                defaults.removeObject(forKey: defaultSourceKey)
            }
        }
    }

    // SMAppService remembers the .app path; moving the .app breaks the
    // login item until the user toggles this off and on again.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
            } catch {
                Log.warn("launch-at-login toggle failed: \(error)")
            }
        }
    }
}
