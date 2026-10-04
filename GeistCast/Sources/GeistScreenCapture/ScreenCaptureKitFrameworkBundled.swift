import Foundation

public enum ScreenCaptureKitFrameworkBundled {
    public enum Error: Swift.Error, Equatable {
        case archiveMissing
    }

    public static func archiveURL() throws -> URL {
        guard let url = Bundle.module.url(
            forResource: "ScreenCaptureKit.framework",
            withExtension: "zip"
        ) else { throw Error.archiveMissing }
        return url
    }
}
