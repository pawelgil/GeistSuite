import Foundation
import Testing
@testable import GeistCast

@Suite struct LiveProcessTests {

    @Test
    func unwrap_zeroStatus_returnsStdout() throws {
        let stdout = Data("hello".utf8)

        let result = try LiveProcessError.unwrap(status: 0, stdout: stdout, stderr: Data())

        #expect(result == stdout)
    }

    @Test
    func unwrap_nonzeroStatus_throwsNonzeroExitWithStatusStdoutStderr() {
        #expect(throws: LiveProcessError.nonzeroExit(
            status: 7, stdout: "out-hint", stderr: "err-boilerplate"
        )) {
            _ = try LiveProcessError.unwrap(
                status: 7,
                stdout: Data("out-hint".utf8),
                stderr: Data("err-boilerplate".utf8)
            )
        }
    }

}
