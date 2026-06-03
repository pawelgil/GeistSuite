import Foundation

public enum GeistShimBundled {

    public enum LookupError: Error, Equatable {
        case dylibMissing(String)
    }

    /// Inject into a host iOS app via `DYLD_INSERT_LIBRARIES` so taps on
    /// `RPSystemBroadcastPickerView` reach the macOS host.
    public static func broadcastAppShimDylibPath() throws -> String {
        try lookup(resource: "GeistBroadcastAppShim")
    }

    static func broadcastExtensionShimDylibPath() throws -> String {
        try lookup(resource: "GeistBroadcastExtensionShim")
    }

    public static var cameraShimDylibPath: String {
        guard let path = Bundle.module.path(forResource: "GeistCamShim", ofType: "dylib") else {
            fatalError("GeistCamShim.dylib missing from resources — build plugin did not run")
        }
        return path
    }

    private static func lookup(resource: String) throws -> String {
        guard let path = Bundle.module.path(forResource: resource, ofType: "dylib") else {
            throw LookupError.dylibMissing(resource)
        }
        return path
    }
}
