import Foundation
import Testing
@testable import GeistCamera

@Suite("MediaSourceFeatures")
struct MediaSourceFeaturesTests {
    @Test func empty_rawValueIsZero() {
        let empty: MediaSourceFeatures = []
        #expect(empty.rawValue == 0)
    }

    @Test func allowsFrontMirror_rawValueIsOne() {
        let f: MediaSourceFeatures = [.allowsFrontMirror]
        #expect(f.rawValue == 1)
    }

    @Test func defaultFeatures_areEmpty() {
        // Default extension provides [] when a MediaSource doesn't declare its own.
        // Verify via a TestPatternMediaSource, which doesn't override.
        let source = TestPatternMediaSource()
        #expect(source.features == [])
    }
}

@Suite("VideoFileMediaSource.features")
struct VideoFileMediaSourceFeaturesTests {
    @Test func features_videoFile_isEmpty() throws {
        let url = try Self.fixtureURL()
        let source = try VideoFileMediaSource(url: url)
        #expect(source.features == [])
    }

    private static func fixtureURL() throws -> URL {
        guard let url = Bundle.module.url(forResource: "AVTwoSeconds", withExtension: "mp4") else {
            throw FixtureError.missing
        }
        return url
    }

    private enum FixtureError: Error { case missing }
}
