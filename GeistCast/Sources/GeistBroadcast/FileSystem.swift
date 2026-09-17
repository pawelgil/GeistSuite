import Darwin
import Foundation

protocol FileSystem: Sendable {
    func claimOwnedDirectory(named name: String) throws -> OwnedDirectoryReceipt
    func removeOwnedDirectory(_ receipt: OwnedDirectoryReceipt) throws
    func fileExists(atPath path: String) -> Bool
    func contentsOfFile(atPath path: String) throws -> Data
    func write(_ data: Data, toPath path: String) throws
    func copyItem(atPath src: String, toPath dst: String) throws
}

struct LiveFileSystem: FileSystem {

    enum LiveFileSystemError: Error, Equatable {
        case createDirectoryFailed(path: String, errno: Int32)
        case inspectDirectoryFailed(path: String, errno: Int32)
        case invalidDirectoryName(String)
        case notFound(String)
        case removeDirectoryFailed(path: String, reason: String)
        case unsafeDirectory(path: String, reason: String)
    }

    init() {}

    func claimOwnedDirectory(named name: String) throws -> OwnedDirectoryReceipt {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\0") else {
            throw LiveFileSystemError.invalidDirectoryName(name)
        }
        let path = "/private/tmp/\(name)"
        guard Darwin.mkdir(path, mode_t(S_IRWXU)) == 0 else {
            throw LiveFileSystemError.createDirectoryFailed(path: path, errno: errno)
        }
        let status = try directoryStatus(atPath: path)
        try validate(status, path: path, expectedReceipt: nil)
        return OwnedDirectoryReceipt(
            canonicalPath: path,
            device: status.st_dev,
            inode: status.st_ino,
            owner: status.st_uid
        )
    }

    func removeOwnedDirectory(_ receipt: OwnedDirectoryReceipt) throws {
        var status = stat()
        guard lstat(receipt.canonicalPath, &status) == 0 else {
            if errno == ENOENT { return }
            throw LiveFileSystemError.inspectDirectoryFailed(
                path: receipt.canonicalPath,
                errno: errno
            )
        }
        try validate(status, path: receipt.canonicalPath, expectedReceipt: receipt)
        do {
            try FileManager.default.removeItem(atPath: receipt.canonicalPath)
        } catch {
            throw LiveFileSystemError.removeDirectoryFailed(
                path: receipt.canonicalPath,
                reason: String(describing: error)
            )
        }
    }

    func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func contentsOfFile(atPath path: String) throws -> Data {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw LiveFileSystemError.notFound(path)
        }
        return data
    }

    func write(_ data: Data, toPath path: String) throws {
        try data.write(to: URL(fileURLWithPath: path))
    }

    func copyItem(atPath src: String, toPath dst: String) throws {
        try FileManager.default.copyItem(atPath: src, toPath: dst)
    }

    private func directoryStatus(atPath path: String) throws -> stat {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            throw LiveFileSystemError.inspectDirectoryFailed(path: path, errno: errno)
        }
        return status
    }

    private func validate(
        _ status: stat,
        path: String,
        expectedReceipt: OwnedDirectoryReceipt?
    ) throws {
        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw LiveFileSystemError.unsafeDirectory(path: path, reason: "not a directory")
        }
        guard status.st_uid == getuid() else {
            throw LiveFileSystemError.unsafeDirectory(path: path, reason: "wrong owner")
        }
        guard status.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO) == S_IRWXU else {
            throw LiveFileSystemError.unsafeDirectory(path: path, reason: "permissions are not 0700")
        }
        guard let expectedReceipt else { return }
        guard status.st_dev == expectedReceipt.device,
              status.st_ino == expectedReceipt.inode,
              status.st_uid == expectedReceipt.owner else {
            throw LiveFileSystemError.unsafeDirectory(path: path, reason: "identity changed")
        }
    }
}
