import Foundation
@testable import GeistCast
import Testing

struct GlobalPreferencesTests {
    @Test
    func screenCaptureKitSupportEnabled_NewStore_DefaultsToDisabled() throws {
        let defaults = try makeDefaults()
        let sut = GlobalPreferences(defaults: defaults)

        #expect(!sut.screenCaptureKitSupportEnabled)
    }

    @Test
    func screenCaptureKitSupportEnabled_Updated_PersistsValue() throws {
        let defaults = try makeDefaults()
        let sut = GlobalPreferences(defaults: defaults)

        sut.screenCaptureKitSupportEnabled = true

        #expect(GlobalPreferences(defaults: defaults).screenCaptureKitSupportEnabled)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "GlobalPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
