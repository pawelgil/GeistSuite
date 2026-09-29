import AVFoundation
import Foundation
import Testing

struct MediaTimingFixtureTests {
    @Test(arguments: [(name: "TimingMarkers", offset: 0.0), (name: "OffsetTimingMarkers", offset: 0.3)])
    func fixture_decodedPixels_encodeSourcePresentationTime(name: String, offset: Double) async throws {
        let samples = try await decodeVideo(name)
        let marked = samples.filter { $0.marker >= 0 }

        #expect(marked.map(\.marker) == Array(0 ..< 60))
        #expect(marked.allSatisfy { abs($0.pts - Double($0.marker) / 30 - offset) < 0.000001 })
        #expect(samples.filter { $0.marker < 0 }.map(\.pts) == (offset > 0 ? [0] : []))
    }

    private func decodeVideo(_ fixture: String) async throws -> [(marker: Int, pts: Double)] {
        let url = try #require(Bundle.module.url(forResource: fixture, withExtension: "mov"))
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        let reader = try AVAssetReader(asset: asset)
        reader.add(output)
        try #require(reader.startReading())
        defer { reader.cancelReading() }
        var samples: [(marker: Int, pts: Double)] = []
        while let sample = output.copyNextSampleBuffer() {
            let pixels = try #require(CMSampleBufferGetImageBuffer(sample))
            try samples.append((readMarker(pixels), sample.presentationTimeStamp.seconds))
        }
        try #require(reader.status == .completed)
        return samples
    }

    private func readMarker(_ pixels: CVPixelBuffer) throws -> Int {
        try #require(CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddressOfPlane(pixels, 0))
        return Int(base.load(as: UInt8.self)) - 32
    }
}
