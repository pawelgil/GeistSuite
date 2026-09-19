import Foundation
import GeistCameraShimCore
import GeistCameraShimTestSupport
import Testing

@Suite("Camera source attributes", .serialized)
struct SourceAttributesTests {
    @Test func resolveSourceAttributes_compatibleModernAndLegacy_prefersModernObject() throws {
        let attributesClass: AnyClass = makeAttributesClass(typeEncoding: "@24@0:8@16")
        let provider = GeistCamTestResolveSourceAttributes(attributesClass, "legacy-key", "modern-key")
        let dictionary: [AnyHashable: Any] = ["value": "modern"]

        let attributes = try #require(GeistCamTestCreateSourceAttributes(provider, dictionary))

        #expect(provider.mode == GeistCamSourceAttributesModeModernObject)
        #expect(GeistCamTestSourceAttributesPropertyKey(provider) == "modern-key")
        #expect(GeistCamTestAttributesDictionary(attributes)?["value"] as? String == "modern")
    }

    @Test func resolveSourceAttributes_incompatibleModernInitializers_usesLegacyDictionary() throws {
        let incompatibleEncodings = [
            "v24@0:8@16",
            "@24#0:8@16",
            "@24@0@8@16",
            "@20@0:8i16",
            "@16@0:8",
        ]

        for encoding in incompatibleEncodings {
            let attributesClass: AnyClass = makeAttributesClass(typeEncoding: encoding)
            let provider = GeistCamTestResolveSourceAttributes(attributesClass, "legacy-key", "modern-key")
            let dictionary: [AnyHashable: Any] = ["encoding": encoding]

            let attributes = try #require(GeistCamTestCreateSourceAttributes(provider, dictionary))

            #expect(provider.mode == GeistCamSourceAttributesModeLegacyDictionary)
            #expect(GeistCamTestSourceAttributesPropertyKey(provider) == "legacy-key")
            #expect((attributes as? [AnyHashable: Any])?["encoding"] as? String == encoding)
        }
    }

    @Test func resolveSourceAttributes_modernInitializerMissing_usesLegacyDictionary() throws {
        let attributesClass: AnyClass = makeAttributesClass(typeEncoding: nil)
        let provider = GeistCamTestResolveSourceAttributes(attributesClass, "legacy-key", "modern-key")
        let dictionary: [AnyHashable: Any] = ["value": "legacy"]

        let attributes = try #require(GeistCamTestCreateSourceAttributes(provider, dictionary))

        #expect(provider.mode == GeistCamSourceAttributesModeLegacyDictionary)
        #expect((attributes as? [AnyHashable: Any])?["value"] as? String == "legacy")
    }

    @Test func resolveSourceAttributes_modernPropertyKeyMissing_usesLegacyDictionary() throws {
        let attributesClass: AnyClass = makeAttributesClass(typeEncoding: "@24@0:8@16")
        let provider = GeistCamTestResolveSourceAttributes(attributesClass, "legacy-key", nil)
        let dictionary: [AnyHashable: Any] = ["value": "legacy"]

        let attributes = try #require(GeistCamTestCreateSourceAttributes(provider, dictionary))

        #expect(provider.mode == GeistCamSourceAttributesModeLegacyDictionary)
        #expect((attributes as? [AnyHashable: Any])?["value"] as? String == "legacy")
    }

    @Test func resolveSourceAttributes_noSupportedRepresentation_returnsUnsupported() {
        let attributesClass: AnyClass = makeAttributesClass(typeEncoding: nil)
        let provider = GeistCamTestResolveSourceAttributes(attributesClass, nil, "modern-key")

        #expect(provider.mode == GeistCamSourceAttributesModeUnsupported)
        #expect(GeistCamTestCreateSourceAttributes(provider, [:]) == nil)
    }

    @Test func createSourceAttributes_retainedModernResult_survivesAutoreleasePool() throws {
        let attributesClass: AnyClass = makeAttributesClass(typeEncoding: "@24@0:8@16")
        let provider = GeistCamTestResolveSourceAttributes(attributesClass, nil, "modern-key")
        var attributes: AnyObject?
        weak var retainedToken: NSObject?

        autoreleasepool {
            let token = NSObject()
            retainedToken = token
            let dictionary: [AnyHashable: Any] = ["token": token]
            attributes = GeistCamTestCreateSourceAttributes(provider, dictionary) as AnyObject?
        }

        #expect(attributes != nil)
        #expect(retainedToken != nil)
        var dictionary: [AnyHashable: Any]? = try #require(GeistCamTestAttributesDictionary(attributes))
        #expect(dictionary?["token"] as AnyObject? === retainedToken)
        dictionary = nil
        attributes = nil
        autoreleasepool {}
        #expect(retainedToken == nil)
    }

    @Test func createSourceAttributes_retainedLegacyDictionary_survivesAutoreleasePool() throws {
        let provider = GeistCamTestResolveSourceAttributes(nil, "legacy-key", nil)
        var attributes: AnyObject?
        weak var retainedToken: NSObject?

        autoreleasepool {
            let token = NSObject()
            retainedToken = token
            attributes = GeistCamTestCreateSourceAttributes(provider, ["token": token]) as AnyObject?
        }

        #expect(retainedToken != nil)
        var dictionary = try #require(attributes as? [AnyHashable: Any])
        #expect(dictionary["token"] as AnyObject? === retainedToken)
        dictionary = [:]
        attributes = nil
        autoreleasepool {}
        #expect(retainedToken == nil)
    }

    @Test func createSourceAttributes_initializerReturnsNil_releasesConsumedReceiver() {
        let attributesClass: AnyClass = makeAttributesClass(
            typeEncoding: "@24@0:8@16",
            behavior: GeistCamTestAttributesBehaviorReturnsNil
        )
        let provider = GeistCamTestResolveSourceAttributes(attributesClass, nil, "modern-key")

        let attributes = GeistCamTestCreateSourceAttributes(provider, [:])

        #expect(attributes == nil)
        #expect(GeistCamTestLastConsumedAttributesReceiverWasDeallocated())
    }

    @Test func createSourceAttributes_initializerReturnsReplacement_releasesReceiverAndRetainsReplacement() throws {
        let attributesClass: AnyClass = makeAttributesClass(
            typeEncoding: "@24@0:8@16",
            behavior: GeistCamTestAttributesBehaviorReturnsReplacement
        )
        let provider = GeistCamTestResolveSourceAttributes(attributesClass, nil, "modern-key")
        let dictionary: [AnyHashable: Any] = ["value": "replacement"]

        let value = try #require(GeistCamTestCreateSourceAttributes(provider, dictionary))
        let attributes = try #require(value as? NSObject)

        #expect(!attributes.isKind(of: attributesClass))
        #expect(GeistCamTestAttributesDictionary(attributes)?["value"] as? String == "replacement")
        #expect(GeistCamTestLastConsumedAttributesReceiverWasDeallocated())
    }

    private func makeAttributesClass(
        typeEncoding: String?,
        behavior: GeistCamTestAttributesBehavior = GeistCamTestAttributesBehaviorReturnsReceiver
    ) -> AnyClass {
        return typeEncoding?.withCString {
            GeistCamTestMakeAttributesClass($0, behavior)
        } ?? GeistCamTestMakeAttributesClass(nil, behavior)
    }
}
