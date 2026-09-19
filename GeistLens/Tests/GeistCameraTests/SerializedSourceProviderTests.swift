import Foundation
import GeistCameraShimCore
import Synchronization
import Testing

@Suite("Serialized camera source provider")
struct SerializedSourceProviderTests {
    @Test func copySources_concurrentCacheableLoads_runsLoaderOnceAndReturnsSameResult() async {
        let provider = SendableSourceProvider()
        let loadCount = Mutex(0)
        var identities: Set<ObjectIdentifier> = []
        var resultCount = 0

        await withTaskGroup(of: ObjectIdentifier?.self) { group in
            for _ in 0 ..< 64 {
                group.addTask {
                    let sources = provider.value.copySources { shouldCache in
                        loadCount.withLock { $0 += 1 }
                        shouldCache.pointee = true
                        return [NSObject()]
                    }
                    guard let token = sources?.first as AnyObject? else { return nil }
                    return ObjectIdentifier(token)
                }
            }
            for await identity in group {
                if let identity {
                    resultCount += 1
                    identities.insert(identity)
                }
            }
        }

        #expect(resultCount == 64)
        #expect(loadCount.withLock { $0 } == 1)
        #expect(identities.count == 1)
    }

    @Test func copySources_uncachedFallbackThenCacheableSuccess_retriesThenCachesSuccess() throws {
        let fallbackToken = NSObject()
        let successToken = NSObject()
        let loader = SequencedSourceLoader([
            ([fallbackToken], false),
            ([successToken], true),
            ([NSObject()], true),
        ])
        let provider = GeistCamSerializedSourceProvider()

        let first = provider.copySources(loader: loader.load)
        let second = provider.copySources(loader: loader.load)
        let third = provider.copySources(loader: loader.load)

        #expect(try token(in: first) === fallbackToken)
        #expect(try token(in: second) === successToken)
        #expect(try token(in: third) === successToken)
    }

    @Test func copySources_nilThenCacheableSuccess_retriesAfterNil() throws {
        let successToken = NSObject()
        let loader = SequencedSourceLoader([
            (nil, false),
            ([successToken], true),
            ([NSObject()], true),
        ])
        let provider = GeistCamSerializedSourceProvider()

        let first = provider.copySources(loader: loader.load)
        let second = provider.copySources(loader: loader.load)
        let third = provider.copySources(loader: loader.load)

        #expect(first == nil)
        #expect(try token(in: second) === successToken)
        #expect(try token(in: third) === successToken)
    }

    private func token(in sources: [Any]?) throws -> AnyObject {
        try #require(sources?.first as AnyObject?)
    }
}

private final class SendableSourceProvider: @unchecked Sendable {
    /// GeistCamSerializedSourceProvider serializes every access with its internal lock.
    let value = GeistCamSerializedSourceProvider()
}

private final class SequencedSourceLoader {
    // MARK: Properties

    private var outcomes: [([Any]?, Bool)]

    // MARK: Lifecycle

    init(_ outcomes: [([Any]?, Bool)]) {
        self.outcomes = outcomes
    }

    // MARK: Functions

    func load(_ shouldCache: UnsafeMutablePointer<ObjCBool>) -> [Any]? {
        guard !outcomes.isEmpty else { return nil }
        let outcome = outcomes.removeFirst()
        shouldCache.pointee = ObjCBool(outcome.1)
        return outcome.0
    }
}
