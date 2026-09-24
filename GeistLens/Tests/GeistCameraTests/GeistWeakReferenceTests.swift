import GeistCameraShimCore
import Testing

struct GeistWeakReferenceTests {
    // MARK: Nested Types

    private final class Delegate {}

    // MARK: Functions

    @Test
    func GeistWeakReference_ReferencedObjectDeallocates_ClearsObject() throws {
        var delegate: Delegate? = Delegate()
        let sut = try GeistWeakReference(object: #require(delegate))

        delegate = nil

        #expect(sut.object == nil)
    }
}
