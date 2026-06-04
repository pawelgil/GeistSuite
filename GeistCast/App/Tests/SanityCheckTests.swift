import Foundation
import Testing
@testable import GeistCast

@Suite("AppSanityCheck")
struct AppSanityCheckTests {
    @Test func bundleIdentifier_isNotEmpty() {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        #expect(!bundleID.isEmpty)
    }
}
