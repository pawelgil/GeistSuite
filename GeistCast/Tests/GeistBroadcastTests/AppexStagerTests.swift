import Foundation
@testable import GeistBroadcast
import Synchronization
import Testing

struct AppexStagerTests {
    @Test
    func stage_ValidAppex_RetainsRootUntilArtifactRelease() async throws {
        let fileSystem = FakeFileSystem()
        let resigner = SpyBundleResigner()
        let sut = AppexStager(fileSystem: fileSystem, resigner: resigner)
        var stagedAppex: StagedAppex? = try await sut.stage(appexAt: "/source/Test.appex")
        let rootPath = try #require(fileSystem.rootPath)
        let stagedPath = "\(rootPath)/BroadcastExtension.appex"

        #expect(stagedAppex?.binaryPath == "\(stagedPath)/Binary")
        #expect(fileSystem.fileExists(atPath: stagedPath))
        #expect(try fileSystem.packageType(atPath: stagedPath) == "APPL")
        #expect(resigner.bundlePaths == [stagedPath])
        #expect(fileSystem.fileExists(atPath: rootPath))

        stagedAppex = nil
        #expect(!fileSystem.fileExists(atPath: rootPath))
    }

    @Test
    func stage_PreexistingClaimTarget_LeavesExistingContentsUntouched() async throws {
        let fileSystem = FakeFileSystem(preexistingClaimTarget: true)
        let sut = AppexStager(fileSystem: fileSystem, resigner: SpyBundleResigner())

        await #expect(throws: StagingTestError.alreadyExists) {
            try await sut.stage(appexAt: "/source/Test.appex")
        }

        let rootPath = try #require(fileSystem.rootPath)
        #expect(fileSystem.fileExists(atPath: rootPath))
        #expect(fileSystem.contents(atPath: "\(rootPath)/sentinel") == Data("kept".utf8))
    }

    @Test
    func stage_CopyFailure_RemovesClaimedRoot() async {
        let fileSystem = FakeFileSystem(failure: .copy)
        let sut = AppexStager(fileSystem: fileSystem, resigner: SpyBundleResigner())

        await #expect(throws: StagingTestError.copy) {
            try await sut.stage(appexAt: "/source/Test.appex")
        }
        #expect(!fileSystem.claimedRootExists)
    }

    @Test
    func stage_PatchFailure_RemovesClaimedRoot() async {
        let fileSystem = FakeFileSystem(failure: .write)
        let sut = AppexStager(fileSystem: fileSystem, resigner: SpyBundleResigner())

        await #expect(throws: StagingTestError.write) {
            try await sut.stage(appexAt: "/source/Test.appex")
        }
        #expect(!fileSystem.claimedRootExists)
    }

    @Test
    func stage_SigningFailure_RemovesClaimedRoot() async {
        let fileSystem = FakeFileSystem()
        let sut = AppexStager(fileSystem: fileSystem, resigner: FailingBundleResigner())

        await #expect(throws: StagingTestError.resign) {
            try await sut.stage(appexAt: "/source/Test.appex")
        }
        #expect(!fileSystem.claimedRootExists)
    }

    @Test
    func stage_MalformedPlist_RemovesClaimedRoot() async {
        let fileSystem = FakeFileSystem(plist: ["not", "a", "dictionary"])
        let sut = AppexStager(fileSystem: fileSystem, resigner: SpyBundleResigner())

        await #expect(throws: AppexStager.StagerError.self) {
            try await sut.stage(appexAt: "/source/Test.appex")
        }
        #expect(!fileSystem.claimedRootExists)
    }

    @Test
    func stage_MissingExecutableName_RemovesClaimedRoot() async {
        let fileSystem = FakeFileSystem(plist: ["CFBundlePackageType": "XPC!"])
        let sut = AppexStager(fileSystem: fileSystem, resigner: SpyBundleResigner())

        await #expect(throws: AppexStager.StagerError.self) {
            try await sut.stage(appexAt: "/source/Test.appex")
        }
        #expect(!fileSystem.claimedRootExists)
    }

    @Test
    func stage_CancelledAfterSigning_RemovesClaimedRoot() async {
        let fileSystem = FakeFileSystem()
        let sut = AppexStager(fileSystem: fileSystem, resigner: CancellingBundleResigner())
        let staging = Task { try await sut.stage(appexAt: "/source/Test.appex") }

        switch await staging.result {
        case let .failure(error):
            #expect(error is CancellationError)
        case .success:
            Issue.record("expected cancellation")
        }
        #expect(!fileSystem.claimedRootExists)
    }

    @Test
    func stage_PrimaryAndCleanupFailure_PreservesPrimaryAndReportsCleanup() async throws {
        let fileSystem = FakeFileSystem(failure: .remove)
        let reporter = CleanupFailureRecorder()
        let sut = AppexStager(
            fileSystem: fileSystem,
            resigner: FailingBundleResigner(),
            cleanupFailureReporter: reporter.record
        )

        await #expect(throws: StagingTestError.resign) {
            try await sut.stage(appexAt: "/source/Test.appex")
        }
        let rootPath = try #require(fileSystem.rootPath)
        #expect(reporter.paths == [rootPath])
        #expect(reporter.reasons == [String(describing: StagingTestError.remove)])
        #expect(fileSystem.claimedRootExists)
    }
}

private enum StagingTestError: Error, Equatable {
    case alreadyExists
    case copy
    case missing
    case remove
    case resign
    case write
}

private final class CleanupFailureRecorder: Sendable {
    // MARK: Nested Types

    private struct State {
        var paths: [String] = []
        var reasons: [String] = []
    }

    // MARK: Properties

    private let state = Mutex(State())

    // MARK: Computed Properties

    var paths: [String] {
        state.withLock(\.paths)
    }

    var reasons: [String] {
        state.withLock(\.reasons)
    }

    // MARK: Functions

    func record(path: String, error: Error) {
        state.withLock {
            $0.paths.append(path)
            $0.reasons.append(String(describing: error))
        }
    }
}

private final class FakeFileSystem: FileSystem, Sendable {
    // MARK: Nested Types

    enum Failure {
        case copy
        case remove
        case write
    }

    private struct State {
        var directories: Set<String>
        var files: [String: Data]
        var rootPath: String?
    }

    // MARK: Properties

    private let failure: Failure?
    private let preexistingClaimTarget: Bool
    private let state: Mutex<State>

    // MARK: Computed Properties

    var claimedRootExists: Bool {
        state.withLock { state in
            state.rootPath.map(state.directories.contains) ?? false
        }
    }

    var rootPath: String? {
        state.withLock(\.rootPath)
    }

    // MARK: Lifecycle

    init(
        failure: Failure? = nil,
        plist: Any = [
            "CFBundleExecutable": "Binary",
            "CFBundlePackageType": "XPC!",
        ],
        preexistingClaimTarget: Bool = false
    ) {
        self.failure = failure
        self.preexistingClaimTarget = preexistingClaimTarget
        let plistData = try! PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        state = Mutex(State(
            directories: ["/source/Test.appex"],
            files: ["/source/Test.appex/Info.plist": plistData],
            rootPath: nil
        ))
    }

    // MARK: Functions

    func claimOwnedDirectory(named name: String) throws -> OwnedDirectoryReceipt {
        let path = "/private/tmp/\(name)"
        let isPreexisting = state.withLock { state -> Bool in
            state.rootPath = path
            guard preexistingClaimTarget else {
                state.directories.insert(path)
                return false
            }
            state.directories.insert(path)
            state.files["\(path)/sentinel"] = Data("kept".utf8)
            return true
        }
        if isPreexisting { throw StagingTestError.alreadyExists }
        return OwnedDirectoryReceipt(canonicalPath: path, device: 1, inode: 2, owner: 3)
    }

    func removeOwnedDirectory(_ receipt: OwnedDirectoryReceipt) throws {
        if failure == .remove { throw StagingTestError.remove }
        state.withLock { state in
            state.directories = state.directories.filter {
                $0 != receipt.canonicalPath && !$0.hasPrefix("\(receipt.canonicalPath)/")
            }
            state.files = state.files.filter {
                !$0.key.hasPrefix("\(receipt.canonicalPath)/")
            }
        }
    }

    func fileExists(atPath path: String) -> Bool {
        state.withLock { $0.directories.contains(path) || $0.files[path] != nil }
    }

    func contentsOfFile(atPath path: String) throws -> Data {
        guard let data = contents(atPath: path) else { throw StagingTestError.missing }
        return data
    }

    func write(_ data: Data, toPath path: String) throws {
        if failure == .write { throw StagingTestError.write }
        state.withLock { $0.files[path] = data }
    }

    func copyItem(atPath src: String, toPath dst: String) throws {
        if failure == .copy { throw StagingTestError.copy }
        try state.withLock { state in
            guard state.directories.contains(src) else { throw StagingTestError.missing }
            state.directories.insert(dst)
            let copiedFiles = state.files.filter { $0.key.hasPrefix("\(src)/") }
            for (path, data) in copiedFiles {
                state.files[path.replacingOccurrences(of: src, with: dst)] = data
            }
        }
    }

    func contents(atPath path: String) -> Data? {
        state.withLock { $0.files[path] }
    }

    func packageType(atPath path: String) throws -> String? {
        let data = try contentsOfFile(atPath: "\(path)/Info.plist")
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        return (value as? [String: Any])?["CFBundlePackageType"] as? String
    }
}

private struct FailingBundleResigner: BundleResigning {
    func resign(bundleAt _: String, scrubbingKey _: String) throws {
        throw StagingTestError.resign
    }
}

private struct CancellingBundleResigner: BundleResigning {
    func resign(bundleAt _: String, scrubbingKey _: String) throws {
        withUnsafeCurrentTask { $0?.cancel() }
    }
}

private final class SpyBundleResigner: BundleResigning, Sendable {
    // MARK: Properties

    private let paths = Mutex<[String]>([])

    // MARK: Computed Properties

    var bundlePaths: [String] {
        paths.withLock { $0 }
    }

    // MARK: Functions

    func resign(bundleAt bundlePath: String, scrubbingKey _: String) throws {
        paths.withLock { $0.append(bundlePath) }
    }
}
