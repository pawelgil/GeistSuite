import Foundation
import GeistCameraShimCore
import GeistCameraShimTestSupport
import Testing

@Suite("Camera source enumeration")
struct SourceEnumerationTests {
    @Test func installHook_compatibleManagerAndLegacy_prefersManagerAndForwardsInvocation() throws {
        let managerClass: AnyClass = makeManagerClass(typeEncoding: "@20@0:8i16")
        let provider = geistcam_installSourceEnumerationHook(
            managerClass,
            GeistCamTestLegacySourceCopier(),
            GeistCamTestReplacementIMP()
        )
        let receiver = GeistCamTestMakeManagerReceiver(managerClass, "receiver-token")
        let selector = NSSelectorFromString("copySourcesWithType:")

        let sources = try #require(geistcam_copyOriginalSources(provider, receiver, selector, 37))

        #expect(provider.mode == GeistCamSourceEnumerationModeManager)
        #expect(sources as? [NSObject] == ["receiver-token" as NSString, "copySourcesWithType:" as NSString, 37 as NSNumber])
    }

    @Test func installHook_incompatibleManagerSignatures_usesLegacy() throws {
        let incompatibleEncodings = [
            "v20@0:8i16",
            "@20#0:8i16",
            "@20@0@8i16",
            "@24@0:8q16",
            "@16@0:8",
        ]

        for encoding in incompatibleEncodings {
            let managerClass: AnyClass = makeManagerClass(typeEncoding: encoding)
            let provider = geistcam_installSourceEnumerationHook(
                managerClass,
                GeistCamTestLegacySourceCopier(),
                GeistCamTestReplacementIMP()
            )

            let sources = try #require(geistcam_copyOriginalSources(provider, nil, nil, 0))

            #expect(provider.mode == GeistCamSourceEnumerationModeLegacy)
            #expect(sources as? [String] == ["legacy"])
        }
    }

    @Test func installHook_managerMissingMethod_usesLegacy() throws {
        let managerClass: AnyClass = makeManagerClass(typeEncoding: nil)

        let provider = geistcam_installSourceEnumerationHook(
            managerClass,
            GeistCamTestLegacySourceCopier(),
            GeistCamTestReplacementIMP()
        )

        #expect(provider.mode == GeistCamSourceEnumerationModeLegacy)
        #expect(try #require(geistcam_copyOriginalSources(provider, nil, nil, 0)) as? [String] == ["legacy"])
    }

    @Test func installHook_managerMissing_usesLegacy() throws {
        let provider = geistcam_installSourceEnumerationHook(
            nil,
            GeistCamTestLegacySourceCopier(),
            GeistCamTestReplacementIMP()
        )

        #expect(provider.mode == GeistCamSourceEnumerationModeLegacy)
        #expect(try #require(geistcam_copyOriginalSources(provider, nil, nil, 0)) as? [String] == ["legacy"])
    }

    @Test func installHook_inheritedManagerMethod_hooksSubclassWithoutChangingSuperclass() throws {
        let superclass: AnyClass = makeManagerClass(typeEncoding: "@20@0:8i16")
        let subclass: AnyClass = GeistCamTestMakeManagerSubclass(superclass)
        let provider = geistcam_installSourceEnumerationHook(
            subclass,
            nil,
            GeistCamTestReplacementIMP()
        )
        let superclassReceiver = GeistCamTestMakeManagerReceiver(superclass, "superclass-token")
        let subclassReceiver = GeistCamTestMakeManagerReceiver(subclass, "subclass-token")

        let superclassSources = GeistCamTestInvokeManager(superclassReceiver, 11)
        let subclassSources = GeistCamTestInvokeManager(subclassReceiver, 12)
        let originalSources = try #require(geistcam_copyOriginalSources(
            provider,
            subclassReceiver,
            NSSelectorFromString("copySourcesWithType:"),
            13
        ))

        #expect(superclassSources as? [NSObject] == ["superclass-token" as NSString, "copySourcesWithType:" as NSString, 11 as NSNumber])
        #expect(subclassSources as? [NSObject] == ["replacement" as NSString, "copySourcesWithType:" as NSString, 12 as NSNumber])
        #expect(originalSources as? [NSObject] == ["subclass-token" as NSString, "copySourcesWithType:" as NSString, 13 as NSNumber])
    }

    @Test func installHook_noCapabilities_returnsUnsupported() {
        let provider = geistcam_installSourceEnumerationHook(nil, nil, GeistCamTestReplacementIMP())

        #expect(provider.mode == GeistCamSourceEnumerationModeUnsupported)
        #expect(geistcam_copyOriginalSources(provider, nil, nil, 0) == nil)
    }

    @Test func copyOriginalSources_retainedManagerResult_survivesAutoreleasePool() throws {
        let managerClass: AnyClass = makeManagerClass(typeEncoding: "@20@0:8i16")
        let provider = geistcam_installSourceEnumerationHook(
            managerClass,
            nil,
            GeistCamTestReplacementIMP()
        )
        var sources: [Any]?
        weak var retainedToken: NSObject?

        autoreleasepool {
            let token = NSObject()
            retainedToken = token
            let receiver = GeistCamTestMakeManagerReceiver(managerClass, token)
            sources = geistcam_copyOriginalSources(
                provider,
                receiver,
                NSSelectorFromString("copySourcesWithType:"),
                91
            )
        }

        #expect(retainedToken != nil)
        #expect(try #require(sources).first as AnyObject? === retainedToken)
        sources = nil
        autoreleasepool {}
        #expect(retainedToken == nil)
    }

    private func makeManagerClass(typeEncoding: String?) -> AnyClass {
        return typeEncoding?.withCString(GeistCamTestMakeManagerClass)
            ?? GeistCamTestMakeManagerClass(nil)
    }
}
