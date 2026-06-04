import Foundation
import Synchronization
import Testing
import GeistKit
@testable import GeistBroadcast

@Suite("AppexStager")
struct AppexStagerTests {

    @Test
    func stage_existingAppex_writesBinaryAtReturnedPath() async throws {
        let source = "/sim/data/Some.appex"
        let fs = FakeFileSystem(initial: [
            "\(source)/Info.plist": makePlistData(packageType: "XPC!", executableName: "Some"),
            "\(source)/Some": Data("binary-bytes".utf8),
        ])
        let sut = createSUT(fileSystem: fs)

        let staged = try await sut.stage(appexAt: source)

        #expect(fs.fileExists(atPath: staged.binaryPath))
    }

    @Test
    func stage_existingAppex_invokesLipoSegeditAndCodesignInOrder() async throws {
        let source = "/sim/data/Some.appex"
        let fs = FakeFileSystem(initial: [
            "\(source)/Info.plist": makePlistData(packageType: "XPC!", executableName: "Some"),
            "\(source)/Some": Data("binary-bytes".utf8),
        ])
        let process = FakeProcessRunner()
        let sut = createSUT(fileSystem: fs, process: process)

        _ = try await sut.stage(appexAt: source)

        #expect(process.calls.map(\.executable) == [
            "/usr/bin/lipo",
            "/usr/bin/xcrun",
            "/usr/bin/codesign",
        ])
    }

    @Test
    func stage_existingAppex_patchesPackageTypeFromXPCToAPPL() async throws {
        let source = "/sim/data/Some.appex"
        let fs = FakeFileSystem(initial: [
            "\(source)/Info.plist": makePlistData(packageType: "XPC!", executableName: "Some"),
            "\(source)/Some": Data("binary-bytes".utf8),
        ])
        let sut = createSUT(fileSystem: fs)

        let staged = try await sut.stage(appexAt: source)

        let appexDir = (staged.binaryPath as NSString).deletingLastPathComponent
        let patchedPlist = try fs.contentsOfFile(atPath: "\(appexDir)/Info.plist")
        let dict = try PropertyListSerialization.propertyList(
            from: patchedPlist, format: nil
        ) as? [String: Any]
        #expect(dict?["CFBundlePackageType"] as? String == "APPL")
    }

    // MARK: helpers

    private func createSUT(
        fileSystem: FakeFileSystem = FakeFileSystem(),
        process: FakeProcessRunner = FakeProcessRunner()
    ) -> AppexStager {
        AppexStager(fileSystem: fileSystem, process: process)
    }

    private func makePlistData(packageType: String, executableName: String) -> Data {
        let plist: [String: Any] = [
            "CFBundlePackageType": packageType,
            "CFBundleExecutable": executableName,
        ]
        return try! PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
    }
}

private final class FakeFileSystem: FileSystem {

    enum FakeError: Error, Equatable { case notFound(String) }

    private let files = Mutex<[String: Data]>([:])

    init(initial: [String: Data] = [:]) {
        files.withLock { $0 = initial }
    }

    func fileExists(atPath path: String) -> Bool {
        files.withLock { dict in
            dict.keys.contains(path) || dict.keys.contains(where: { $0.hasPrefix("\(path)/") })
        }
    }

    func contentsOfFile(atPath path: String) throws -> Data {
        try files.withLock { dict in
            guard let data = dict[path] else { throw FakeError.notFound(path) }
            return data
        }
    }

    func write(_ data: Data, toPath path: String) throws {
        files.withLock { $0[path] = data }
    }

    func copyItem(atPath src: String, toPath dst: String) throws {
        files.withLock { dict in
            let entries = dict.filter { $0.key == src || $0.key.hasPrefix("\(src)/") }
            for (path, data) in entries {
                let suffix = path.dropFirst(src.count)
                let newPath = dst + suffix
                dict[newPath] = data
            }
        }
    }

}

private final class FakeProcessRunner: ProcessRunner {

    private let invocations = Mutex<[ProcessInvocation]>([])

    var calls: [ProcessInvocation] {
        invocations.withLock { $0 }
    }

    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        invocations.withLock { $0.append(invocation) }
        return ProcessResult(exitStatus: 0, stdout: Data(), stderr: Data())
    }
}
