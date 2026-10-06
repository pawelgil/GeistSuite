import Foundation
import GeistBroadcastShimCore
import Testing

struct AppGroupContainerAliasesTests {
    // MARK: Nested Types

    private struct Fixture {
        // MARK: Properties

        let root: URL
        let container: URL
        let aliases: URL

        // MARK: Lifecycle

        init() throws {
            var template = Array("/tmp/gct-XXXXXX".utf8CString)
            let path = try #require(mkdtemp(&template))
            root = URL(fileURLWithPath: String(cString: path), isDirectory: true)
            aliases = root.appendingPathComponent("a", isDirectory: true)
            container = root.appendingPathComponent(String(repeating: "container", count: 20), isDirectory: true)
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        }

        // MARK: Functions

        func createSUT() -> GCAppGroupContainerAliases {
            GCAppGroupContainerAliases(directoryURL: aliases)
        }

        func concurrentAliases(count: Int) async -> [URL?] {
            await withTaskGroup(of: URL?.self, returning: [URL?].self) { group in
                for _ in 0 ..< count {
                    group.addTask { createSUT().containerURL(for: container) }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: Functions

    @Test func containerURL_nil_preservesMissingContainer() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(fixture.createSUT().containerURL(for: nil) == nil)
    }

    @Test func containerURL_shortPath_preservesOriginalURL() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(fixture.createSUT().containerURL(for: fixture.root) == fixture.root)
        #expect(!FileManager.default.fileExists(atPath: fixture.aliases.path))
    }

    @Test func containerURL_longPath_returnsShortAliasToContainer() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sut = fixture.createSUT()

        let result = try #require(sut.containerURL(for: fixture.container))

        #expect(result.path.utf8.count <= 63)
        #expect(result.resolvingSymlinksInPath() == fixture.container.resolvingSymlinksInPath())
    }

    @Test func containerURL_independentInstances_returnSameAlias() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let host = fixture.createSUT().containerURL(for: fixture.container)
        let broadcast = fixture.createSUT().containerURL(for: fixture.container)

        #expect(host == broadcast)
        #expect(host != fixture.container)
    }

    @Test func containerURL_concurrentCreators_shareUsableAlias() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let paths = await fixture.concurrentAliases(count: 32)

        let first = try #require(paths.first)
        let alias = try #require(first)
        #expect(paths == Array(repeating: alias, count: 32))
        #expect(alias.resolvingSymlinksInPath() == fixture.container.resolvingSymlinksInPath())
        #expect(alias != fixture.container)
    }

    @Test func containerURL_newContainer_keepsPreviousAliasIntact() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let originalAlias = try #require(fixture.createSUT().containerURL(for: fixture.container))
        let replacement = fixture.container.appendingPathComponent("reinstalled", isDirectory: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)

        let replacementAlias = try #require(fixture.createSUT().containerURL(for: replacement))

        #expect(replacementAlias != originalAlias)
        #expect(originalAlias.resolvingSymlinksInPath() == fixture.container.resolvingSymlinksInPath())
        #expect(replacementAlias.resolvingSymlinksInPath() == replacement.resolvingSymlinksInPath())
    }

    @Test func containerURL_equivalentTargetPaths_returnSameAlias() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let alternate = fixture.container.appendingPathComponent("alternate", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alternate, withDestinationURL: fixture.container)

        let first = fixture.createSUT().containerURL(for: fixture.container)
        let second = fixture.createSUT().containerURL(for: alternate)

        #expect(first == second)
    }

    @Test func containerURL_multibytePath_usesByteBudget() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let container = fixture.root.appendingPathComponent(String(repeating: "界", count: 20), isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        #expect(container.path.count < 63)
        #expect(container.path.utf8.count > 63)

        let result = try #require(fixture.createSUT().containerURL(for: container))

        #expect(result.path.utf8.count <= 63)
        #expect(result.resolvingSymlinksInPath() == container.resolvingSymlinksInPath())
    }

    @Test func containerURL_missingTarget_preservesOriginalURL() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let missing = fixture.container.appendingPathComponent("missing")

        #expect(fixture.createSUT().containerURL(for: missing) == missing)
    }

    @Test func containerURL_regularFile_preservesOriginalURL() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.container.appendingPathComponent("file")
        try Data().write(to: file)

        #expect(fixture.createSUT().containerURL(for: file) == file)
    }

    @Test func containerURL_unavailableAliasRoot_preservesOriginalURL() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.aliases)

        #expect(fixture.createSUT().containerURL(for: fixture.container) == fixture.container)
        #expect(try Data(contentsOf: fixture.aliases).isEmpty)
    }

    @Test func containerURL_occupiedAlias_preservesExistingFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let alias = try #require(fixture.createSUT().containerURL(for: fixture.container))
        try FileManager.default.removeItem(at: alias)
        let contents = Data("unrelated file".utf8)
        try contents.write(to: alias)

        let result = fixture.createSUT().containerURL(for: fixture.container)

        #expect(result == fixture.container)
        #expect(try Data(contentsOf: alias) == contents)
    }

    @Test func containerURL_wrongAliasTarget_preservesExistingLink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let alias = try #require(fixture.createSUT().containerURL(for: fixture.container))
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)

        let result = fixture.createSUT().containerURL(for: fixture.container)

        #expect(result == fixture.container)
        #expect(alias.resolvingSymlinksInPath() == fixture.root.resolvingSymlinksInPath())
    }

    @Test func containerURL_insecureDirectory_preservesOriginalURL() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.aliases, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.aliases.path)

        #expect(fixture.createSUT().containerURL(for: fixture.container) == fixture.container)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.aliases.path).isEmpty)
    }

    @Test func containerURL_symlinkDirectory_doesNotFollowLink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createSymbolicLink(at: fixture.aliases, withDestinationURL: fixture.container)

        #expect(fixture.createSUT().containerURL(for: fixture.container) == fixture.container)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.container.path).isEmpty)
    }

    @Test func containerURL_oversizedAliasDirectory_preservesOriginalURL() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sut = GCAppGroupContainerAliases(directoryURL: fixture.container)

        #expect(sut.containerURL(for: fixture.container) == fixture.container)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.container.path).isEmpty)
    }

    @Test func containerURL_aliasWrites_areVisibleInRealContainer() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let alias = try #require(fixture.createSUT().containerURL(for: fixture.container))
        let data = Data("shared contents".utf8)

        try data.write(to: alias.appendingPathComponent("shared.txt"))

        #expect(try Data(contentsOf: fixture.container.appendingPathComponent("shared.txt")) == data)
    }
}
