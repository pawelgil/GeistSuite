import Testing
import GeistCameraShimCore

@Suite("geistcam_shouldMirror")
struct GeistCamShouldMirrorTests {
    @Test func noFeatures_connNotMirrored_returnsFalse() {
        #expect(geistcam_shouldMirror(0, false) == false)
    }

    @Test func noFeatures_connMirrored_ignoresAndReturnsFalse() {
        // Source doesn't opt into front-cam mirror, so connection's request
        // is ignored — content stays un-flipped (mp4/image/pattern behavior).
        #expect(geistcam_shouldMirror(0, true) == false)
    }

    @Test func featureSet_connNotMirrored_returnsFalse() {
        // Source allows mirror, but the iOS app isn't asking for it.
        let features = UInt32(GEISTCAM_FEATURE_ALLOWS_FRONT_MIRROR)
        #expect(geistcam_shouldMirror(features, false) == false)
    }

    @Test func featureSet_connMirrored_returnsTrue() {
        // Live-capture source on a front-cam connection that asks for mirror.
        let features = UInt32(GEISTCAM_FEATURE_ALLOWS_FRONT_MIRROR)
        #expect(geistcam_shouldMirror(features, true) == true)
    }
}
