import Foundation
import Testing
@testable import GeistLens

@Suite("ShimInjector")
struct ShimInjectorTests {
    @Test func injectDylib_emptyEnv_setsToOwnPath() {
        let runnerSpy = SimctlRunnerSpy()
        let injector = ShimInjector(runner: runnerSpy, shimLogPath: "/tmp/shim.log")

        _ = injector.injectDylib("/Library/Foo.dylib", intoSimulator: "UDID-1")

        let setenvCalls = runnerSpy.calls.filter {
            $0.args.count >= 4 && $0.args[1] == "setenv" && $0.args[2] == "DYLD_INSERT_LIBRARIES"
        }
        #expect(setenvCalls.count == 1)
        #expect(setenvCalls[0].args == ["launchctl", "setenv", "DYLD_INSERT_LIBRARIES", "/Library/Foo.dylib"])
    }

    @Test func injectDylib_existingOtherPath_appendsSelf() {
        let runnerSpy = SimctlRunnerSpy()
        runnerSpy.capturedValue = "/Library/Other.dylib"
        let injector = ShimInjector(runner: runnerSpy, shimLogPath: "/tmp/shim.log")

        _ = injector.injectDylib("/Library/Foo.dylib", intoSimulator: "UDID-1")

        let setenvCalls = runnerSpy.calls.filter {
            $0.args.count >= 4 && $0.args[1] == "setenv" && $0.args[2] == "DYLD_INSERT_LIBRARIES"
        }
        #expect(setenvCalls[0].args == ["launchctl", "setenv", "DYLD_INSERT_LIBRARIES",
                                          "/Library/Other.dylib:/Library/Foo.dylib"])
    }

    @Test func injectDylib_existingAlreadyContainsSelf_doesNotDuplicate() {
        let runnerSpy = SimctlRunnerSpy()
        runnerSpy.capturedValue = "/Library/Other.dylib:/Library/Foo.dylib"
        let injector = ShimInjector(runner: runnerSpy, shimLogPath: "/tmp/shim.log")

        _ = injector.injectDylib("/Library/Foo.dylib", intoSimulator: "UDID-1")

        let setenvCalls = runnerSpy.calls.filter {
            $0.args.count >= 4 && $0.args[1] == "setenv" && $0.args[2] == "DYLD_INSERT_LIBRARIES"
        }
        #expect(setenvCalls[0].args[3] == "/Library/Other.dylib:/Library/Foo.dylib")
    }

    @Test func injectDylib_dylibCallReturnsFalse_returnsFalse() {
        let runnerStub = FailingSimctlRunnerStub()
        let injector = ShimInjector(runner: runnerStub, shimLogPath: "/tmp/shim.log")

        let result = injector.injectDylib("/Library/Foo.dylib", intoSimulator: "UDID-1")

        #expect(result == false)
    }

    @Test func uninjectDylib_soleEntry_unsetsEntirely() {
        let runnerSpy = SimctlRunnerSpy()
        runnerSpy.capturedValue = "/Library/Foo.dylib"
        let injector = ShimInjector(runner: runnerSpy, shimLogPath: "/tmp/shim.log")

        _ = injector.uninjectDylib("/Library/Foo.dylib", fromSimulator: "UDID-2")

        let unsetenvCalls = runnerSpy.calls.filter {
            $0.args.count >= 3 && $0.args[1] == "unsetenv" && $0.args[2] == "DYLD_INSERT_LIBRARIES"
        }
        #expect(unsetenvCalls.count == 1)
    }

    @Test func uninjectDylib_otherEntriesRemain_setsRemaining() {
        let runnerSpy = SimctlRunnerSpy()
        runnerSpy.capturedValue = "/Library/Other.dylib:/Library/Foo.dylib"
        let injector = ShimInjector(runner: runnerSpy, shimLogPath: "/tmp/shim.log")

        _ = injector.uninjectDylib("/Library/Foo.dylib", fromSimulator: "UDID-2")

        let setenvCalls = runnerSpy.calls.filter {
            $0.args.count >= 3 && $0.args[1] == "setenv" && $0.args[2] == "DYLD_INSERT_LIBRARIES"
        }
        #expect(setenvCalls.count == 1)
        #expect(setenvCalls[0].args[3] == "/Library/Other.dylib")
    }

    @Test func uninjectDylib_dylibUnsetReturnsFalse_returnsFalse() {
        let runnerStub = FailingSimctlRunnerStub()
        let injector = ShimInjector(runner: runnerStub, shimLogPath: "/tmp/shim.log")

        let result = injector.uninjectDylib("/Library/Foo.dylib", fromSimulator: "UDID-2")

        #expect(result == false)
    }

    @Test func appending_pathPreservesOrder() {
        #expect(ShimInjector.appending("/b", to: "") == "/b")
        #expect(ShimInjector.appending("/b", to: "/a") == "/a:/b")
        #expect(ShimInjector.appending("/b", to: "/a:/b") == "/a:/b")
        #expect(ShimInjector.appending("/b", to: "/a:/b:/c") == "/a:/b:/c")
    }

    @Test func removing_dropsOnlyTargetEntry() {
        #expect(ShimInjector.removing("/b", from: "/a:/b:/c") == "/a:/c")
        #expect(ShimInjector.removing("/x", from: "/a:/b") == "/a:/b")
        #expect(ShimInjector.removing("/a", from: "/a") == "")
    }
}

private final class SimctlRunnerSpy: SimctlRunning, @unchecked Sendable {
    struct Call: Sendable, Equatable {
        let udid: String
        let args: [String]
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var capturedValue: String?

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func runSimctl(udid: String, args: [String]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        _calls.append(Call(udid: udid, args: args))
        return true
    }

    func captureSimctl(udid: String, args: [String]) -> String? {
        lock.lock(); defer { lock.unlock() }
        _calls.append(Call(udid: udid, args: args))
        return capturedValue
    }
}

private struct FailingSimctlRunnerStub: SimctlRunning {
    func runSimctl(udid: String, args: [String]) -> Bool { false }
    func captureSimctl(udid: String, args: [String]) -> String? { nil }
}
