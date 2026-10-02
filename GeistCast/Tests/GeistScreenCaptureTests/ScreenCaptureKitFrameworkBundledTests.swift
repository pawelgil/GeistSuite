import Foundation
@testable import GeistScreenCapture
import Testing

struct ScreenCaptureKitFrameworkBundledTests {
    @Test
    func archiveURL_FrameworkBuilt_ResolvesBundledZip() throws {
        let url = try ScreenCaptureKitFrameworkBundled.archiveURL()

        #expect(url.lastPathComponent == "ScreenCaptureKit.framework.zip")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
