import Foundation

public enum GeistBroadcastShimBundled {

    public enum LookupError: Error, Equatable {
        case dylibMissing(String)
    }

    /// Inject into a host iOS app via `DYLD_INSERT_LIBRARIES` so taps on
    /// `RPSystemBroadcastPickerView` reach the macOS host.
    public static func appShimDylibPath() throws -> String {
        try lookup(resource: "GeistBroadcastAppShim")
    }

    static func extensionShimDylibPath() throws -> String {
        try lookup(resource: "GeistBroadcastExtensionShim")
    }

    private static func lookup(resource: String) throws -> String {
        guard let path = Bundle.module.path(forResource: resource, ofType: "dylib") else {
            throw LookupError.dylibMissing(resource)
        }
        return path
    }
}
