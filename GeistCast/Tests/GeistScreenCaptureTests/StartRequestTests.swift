import Foundation
@testable import GeistScreenCapture
import GeistScreenCaptureShimCore
import Testing

struct StartRequestTests {
    @Test
    func decode_ValidScreenAndMicrophone_ReturnsRequestedOutputs() throws {
        let data = requestData(outputs: GEIST_SCK_OUTPUT_SCREEN | GEIST_SCK_OUTPUT_MICROPHONE)

        let request = try StartRequest.decode(data)

        #expect(request.outputs == [.screen, .microphone])
    }

    @Test
    func decode_AppAudio_ReturnsNotSupported() {
        let data = requestData(outputs: GEIST_SCK_OUTPUT_AUDIO)

        #expect(throws: StartRequest.Error.notSupported) {
            try StartRequest.decode(data)
        }
    }

    @Test
    func decode_WrongVersion_ReturnsInvalidRequest() {
        let data = requestData(version: 99, outputs: GEIST_SCK_OUTPUT_SCREEN)

        #expect(throws: StartRequest.Error.invalidRequest) {
            try StartRequest.decode(data)
        }
    }

    private func requestData(
        version: UInt32 = GEIST_SCK_WIRE_VERSION,
        outputs: UInt32
    ) -> Data {
        var request = geist_sck_start_request_t(
            magic: GEIST_SCK_WIRE_MAGIC,
            version: version,
            outputs: outputs
        )
        return withUnsafeBytes(of: &request) { Data($0) }
    }
}
