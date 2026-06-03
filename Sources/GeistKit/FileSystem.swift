import Foundation

public protocol FileSystem: Sendable {
    func fileExists(atPath path: String) -> Bool
    func contentsOfFile(atPath path: String) throws -> Data
    func write(_ data: Data, toPath path: String) throws
    func copyItem(atPath src: String, toPath dst: String) throws
}

public struct LiveFileSystem: FileSystem {

    public enum LiveFileSystemError: Error, Equatable {
        case notFound(String)
    }

    public init() {}

    public func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func contentsOfFile(atPath path: String) throws -> Data {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw LiveFileSystemError.notFound(path)
        }
        return data
    }

    public func write(_ data: Data, toPath path: String) throws {
        try data.write(to: URL(fileURLWithPath: path))
    }

    public func copyItem(atPath src: String, toPath dst: String) throws {
        try FileManager.default.copyItem(atPath: src, toPath: dst)
    }
}
