import Testing
import GeistBroadcastShimCore

@Suite struct GeistBroadcastShimCoreTests {

    @Test
    func encodeEventLine_bufferTooSmall_returnsMinusOne() {
        var buffer = [CChar](repeating: 0, count: 10)
        let length = buffer.withUnsafeMutableBufferPointer { bp -> Int32 in
            geistbroadcast_encode_event_line(
                "started", "S", "H", "E", "T", bp.baseAddress, bp.count
            )
        }
        #expect(length == -1)
    }

    @Test
    func encodeEventLine_validFields_writesExpectedJSON() {
        var buffer = [CChar](repeating: 0, count: 512)
        let length = buffer.withUnsafeMutableBufferPointer { bp -> Int32 in
            geistbroadcast_encode_event_line(
                "started",
                "SIM-UDID",
                "com.host",
                "com.host.cast",
                "2026-01-01T00:00:00Z",
                bp.baseAddress,
                bp.count
            )
        }

        #expect(length > 0)
        #expect(String(cString: buffer) == #"{"type":"started","simulatorUDID":"SIM-UDID","hostAppBundleID":"com.host","extensionBundleID":"com.host.cast","startedAt":"2026-01-01T00:00:00Z"}"#)
    }
}
