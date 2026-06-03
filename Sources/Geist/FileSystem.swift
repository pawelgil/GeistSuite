import Foundation

protocol FileSystem: Sendable {
    func fileExists(atPath path: String) -> Bool
    func contentsOfFile(atPath path: String) throws -> Data
    func write(_ data: Data, toPath path: String) throws
    func copyItem(atPath src: String, toPath dst: String) throws
}

struct LiveFileSystem: FileSystem {

    enum LiveFileSystemError: Error, Equatable {
        case notFound(String)
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
}
