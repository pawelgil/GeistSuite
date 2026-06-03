import Foundation
import Testing
import GeistBroadcast
@testable import GeistCast

@Suite struct LaunchctlShimInjectorTests {

    @Test
    func injectDylib_emptyEnv_setsToOwnPath() async throws {
        let spy = SpyProcess(capturedValue: "")
        let sut = LaunchctlShimInjector(process: spy)

        try await sut.injectDylib(at: "/some/path.dylib", intoSimulator: "SIM-UDID")

        let setenvCalls = await spy.invocations.filter {
            $0.arguments.contains("setenv") && $0.arguments.contains("DYLD_INSERT_LIBRARIES")
        }
        #expect(setenvCalls.count == 1)
        #expect(setenvCalls[0].arguments.last == "/some/path.dylib")
    }

    @Test
    func injectDylib_existingOtherPath_appendsSelf() async throws {
        let spy = SpyProcess(capturedValue: "/Library/Other.dylib")
        let sut = LaunchctlShimInjector(process: spy)

        try await sut.injectDylib(at: "/some/path.dylib", intoSimulator: "SIM-UDID")

        let setenvCalls = await spy.invocations.filter {
            $0.arguments.contains("setenv") && $0.arguments.contains("DYLD_INSERT_LIBRARIES")
        }
        #expect(setenvCalls.count == 1)
        #expect(setenvCalls[0].arguments.last == "/Library/Other.dylib:/some/path.dylib")
    }

    @Test
    func injectDylib_existingAlreadyContainsSelf_doesNotDuplicate() async throws {
        let spy = SpyProcess(capturedValue: "/Library/Other.dylib:/some/path.dylib")
        let sut = LaunchctlShimInjector(process: spy)

        try await sut.injectDylib(at: "/some/path.dylib", intoSimulator: "SIM-UDID")

        let setenvCalls = await spy.invocations.filter {
            $0.arguments.contains("setenv") && $0.arguments.contains("DYLD_INSERT_LIBRARIES")
        }
        #expect(setenvCalls.count == 1)
        #expect(setenvCalls[0].arguments.last == "/Library/Other.dylib:/some/path.dylib")
    }

    @Test
    func uninjectDylib_soleEntry_unsetsEntirely() async throws {
        let spy = SpyProcess(capturedValue: "/some/path.dylib")
        let sut = LaunchctlShimInjector(process: spy)

        try await sut.uninjectDylib(at: "/some/path.dylib", fromSimulator: "SIM-UDID")

        let unsetenvCalls = await spy.invocations.filter {
            $0.arguments.contains("unsetenv") && $0.arguments.contains("DYLD_INSERT_LIBRARIES")
        }
        #expect(unsetenvCalls.count == 1)
    }

    @Test
    func uninjectDylib_otherEntriesRemain_setsRemaining() async throws {
        let spy = SpyProcess(capturedValue: "/Library/Other.dylib:/some/path.dylib")
        let sut = LaunchctlShimInjector(process: spy)

        try await sut.uninjectDylib(at: "/some/path.dylib", fromSimulator: "SIM-UDID")

        let setenvCalls = await spy.invocations.filter {
            $0.arguments.contains("setenv") && $0.arguments.contains("DYLD_INSERT_LIBRARIES")
        }
        #expect(setenvCalls.count == 1)
        #expect(setenvCalls[0].arguments.last == "/Library/Other.dylib")
    }

    @Test
    func appending_pathPreservesOrder() {
        #expect(LaunchctlShimInjector.appending("/b", to: "") == "/b")
        #expect(LaunchctlShimInjector.appending("/b", to: "/a") == "/a:/b")
        #expect(LaunchctlShimInjector.appending("/b", to: "/a:/b") == "/a:/b")
        #expect(LaunchctlShimInjector.appending("/b", to: "/a:/b:/c") == "/a:/b:/c")
    }

    @Test
    func removing_dropsOnlyTargetEntry() {
        #expect(LaunchctlShimInjector.removing("/b", from: "/a:/b:/c") == "/a:/c")
        #expect(LaunchctlShimInjector.removing("/x", from: "/a:/b") == "/a:/b")
        #expect(LaunchctlShimInjector.removing("/a", from: "/a") == "")
    }

    private struct ProcessInvocation: Sendable, Equatable {
        let executable: String
        let arguments: [String]
    }

    private actor SpyProcess: ProcessRunning {
        private(set) var invocations: [ProcessInvocation] = []
        private let capturedValue: String

        init(capturedValue: String = "") {
            self.capturedValue = capturedValue
        }

        func run(executable: String, arguments: [String]) async throws -> Data {
            invocations.append(ProcessInvocation(executable: executable, arguments: arguments))
            if arguments.contains("getenv") {
                return Data(capturedValue.utf8)
            }
            return Data()
        }
    }
}
