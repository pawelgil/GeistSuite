import Darwin
import Foundation
@testable import GeistBroadcast
import Testing

struct FileSystemTests {
    @Test
    func claimOwnedDirectory_FreshName_CreatesCanonicalPrivateDirectory() throws {
        let sut = LiveFileSystem()
        let receipt = try sut.claimOwnedDirectory(named: uniqueName())
        defer { removeFixture(receipt, using: sut) }
        var status = stat()

        let result = lstat(receipt.canonicalPath, &status)

        #expect(result == 0)
        #expect(receipt.canonicalPath.hasPrefix("/private/tmp/geistcast-staged-appex-test-"))
        #expect(status.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO) == S_IRWXU)
        #expect(status.st_uid == getuid())
        #expect(receipt.device == status.st_dev)
        #expect(receipt.inode == status.st_ino)

        try sut.removeOwnedDirectory(receipt)
        #expect(!FileManager.default.fileExists(atPath: receipt.canonicalPath))
        try sut.removeOwnedDirectory(receipt)
    }

    @Test
    func claimOwnedDirectory_ExistingName_LeavesExistingContentsUntouched() throws {
        let name = uniqueName()
        let path = "/private/tmp/\(name)"
        let sentinel = "\(path)/sentinel"
        defer { removeFixture(atPath: path) }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        FileManager.default.createFile(atPath: sentinel, contents: Data("kept".utf8))

        #expect(throws: LiveFileSystem.LiveFileSystemError.self) {
            try LiveFileSystem().claimOwnedDirectory(named: name)
        }
        #expect(FileManager.default.contents(atPath: sentinel) == Data("kept".utf8))
    }

    @Test
    func claimOwnedDirectory_EmbeddedNull_RejectsWithoutCreatingTruncatedPath() {
        let prefix = uniqueName()
        let truncatedPath = "/private/tmp/\(prefix)"

        #expect(throws: LiveFileSystem.LiveFileSystemError.invalidDirectoryName("\(prefix)\0suffix")) {
            try LiveFileSystem().claimOwnedDirectory(named: "\(prefix)\0suffix")
        }
        #expect(!FileManager.default.fileExists(atPath: truncatedPath))
    }

    @Test
    func removeOwnedDirectory_ReplacedBySymlink_RefusesForeignDeletion() throws {
        let sut = LiveFileSystem()
        let receipt = try sut.claimOwnedDirectory(named: uniqueName())
        let displacedPath = "\(receipt.canonicalPath)-displaced"
        let foreignPath = "/private/tmp/\(uniqueName())-foreign"
        let sentinel = "\(foreignPath)/sentinel"
        defer {
            removeFixture(atPath: receipt.canonicalPath)
            removeFixture(atPath: displacedPath)
            removeFixture(atPath: foreignPath)
        }
        try FileManager.default.moveItem(atPath: receipt.canonicalPath, toPath: displacedPath)
        try FileManager.default.createDirectory(atPath: foreignPath, withIntermediateDirectories: false)
        FileManager.default.createFile(atPath: sentinel, contents: Data("kept".utf8))
        try FileManager.default.createSymbolicLink(
            atPath: receipt.canonicalPath,
            withDestinationPath: foreignPath
        )
        #expect(throws: LiveFileSystem.LiveFileSystemError.self) {
            try sut.removeOwnedDirectory(receipt)
        }
        #expect(FileManager.default.contents(atPath: sentinel) == Data("kept".utf8))
    }

    @Test
    func removeOwnedDirectory_ReplacedByNewDirectory_RefusesDeletion() throws {
        let sut = LiveFileSystem()
        let receipt = try sut.claimOwnedDirectory(named: uniqueName())
        let displacedPath = "\(receipt.canonicalPath)-displaced"
        defer {
            removeFixture(atPath: receipt.canonicalPath)
            removeFixture(atPath: displacedPath)
        }
        try FileManager.default.moveItem(
            atPath: receipt.canonicalPath,
            toPath: displacedPath
        )
        try FileManager.default.createDirectory(
            atPath: receipt.canonicalPath,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let sentinel = "\(receipt.canonicalPath)/sentinel"
        FileManager.default.createFile(atPath: sentinel, contents: Data("kept".utf8))

        #expect(throws: LiveFileSystem.LiveFileSystemError.self) {
            try sut.removeOwnedDirectory(receipt)
        }
        #expect(FileManager.default.contents(atPath: sentinel) == Data("kept".utf8))
    }

    @Test
    func removeOwnedDirectory_ReplacedByFile_RefusesDeletion() throws {
        let sut = LiveFileSystem()
        let receipt = try sut.claimOwnedDirectory(named: uniqueName())
        defer { removeFixture(atPath: receipt.canonicalPath) }
        try FileManager.default.removeItem(atPath: receipt.canonicalPath)
        FileManager.default.createFile(
            atPath: receipt.canonicalPath,
            contents: Data("kept".utf8)
        )

        #expect(throws: LiveFileSystem.LiveFileSystemError.self) {
            try sut.removeOwnedDirectory(receipt)
        }
        #expect(FileManager.default.contents(atPath: receipt.canonicalPath) == Data("kept".utf8))
    }

    @Test
    func removeOwnedDirectory_WrongDeviceReceipt_RefusesDeletion() throws {
        try assertIdentityChangeRefused { receipt in
            OwnedDirectoryReceipt(
                canonicalPath: receipt.canonicalPath,
                device: receipt.device + 1,
                inode: receipt.inode,
                owner: receipt.owner
            )
        }
    }

    @Test
    func removeOwnedDirectory_WrongInodeReceipt_RefusesDeletion() throws {
        try assertIdentityChangeRefused { receipt in
            OwnedDirectoryReceipt(
                canonicalPath: receipt.canonicalPath,
                device: receipt.device,
                inode: receipt.inode + 1,
                owner: receipt.owner
            )
        }
    }

    @Test
    func removeOwnedDirectory_WrongOwnerReceipt_RefusesDeletion() throws {
        try assertIdentityChangeRefused { receipt in
            OwnedDirectoryReceipt(
                canonicalPath: receipt.canonicalPath,
                device: receipt.device,
                inode: receipt.inode,
                owner: receipt.owner + 1
            )
        }
    }

    private func assertIdentityChangeRefused(
        changing receipt: (OwnedDirectoryReceipt) -> OwnedDirectoryReceipt
    ) throws {
        let sut = LiveFileSystem()
        let owned = try sut.claimOwnedDirectory(named: uniqueName())
        defer { removeFixture(owned, using: sut) }

        #expect(throws: LiveFileSystem.LiveFileSystemError.self) {
            try sut.removeOwnedDirectory(receipt(owned))
        }
        #expect(FileManager.default.fileExists(atPath: owned.canonicalPath))
    }

    private func uniqueName() -> String {
        "geistcast-staged-appex-test-\(UUID().uuidString)"
    }

    private func removeFixture(_ receipt: OwnedDirectoryReceipt, using fileSystem: LiveFileSystem) {
        do {
            try fileSystem.removeOwnedDirectory(receipt)
        } catch {
            Issue.record("failed to remove test-owned directory \(receipt.canonicalPath): \(error)")
        }
    }

    private func removeFixture(atPath path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            Issue.record("failed to remove test-owned path \(path): \(error)")
        }
    }
}
