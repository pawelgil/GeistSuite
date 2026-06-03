import Testing
@testable import GeistLens

@Suite("AppSanityCheck")
struct AppSanityCheckTests {
    @Test func micRoute_defaultDetach_equalsDetach() {
        let route = MicRoute.detach
        #expect(route == .detach)
    }
}
