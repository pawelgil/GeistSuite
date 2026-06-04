import Testing
@testable import GeistCamera

@Suite("SanityCheck")
struct SanityCheckTests {
    @Test func videoSlotFormat_explicitWidth_storesValue() {
        let format = VideoSlotFormat(width: 1280, height: 720, pixelFormat: .yuv420FullRange, fps: 30)
        #expect(format.width == 1280)
    }
}
