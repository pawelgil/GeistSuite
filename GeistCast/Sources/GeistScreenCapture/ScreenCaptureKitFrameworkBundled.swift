import Foundation

public enum ScreenCaptureKitFrameworkBundled {
    // MARK: Nested Types

    public enum Error: Swift.Error, Equatable {
        case archiveMissing
    }

    // MARK: Static Functions

    public static func archiveURL() throws -> URL {
        guard let url = Bundle.module.url(
            forResource: "ScreenCaptureKit.framework",
            withExtension: "zip"
        ) else { throw Error.archiveMissing }
        return url
    }
}
