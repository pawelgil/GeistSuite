import Foundation
@testable import GeistCamera
import Testing

struct GeistCamShimArtifactTests {
    // MARK: Computed Properties

    private var dynamicallyResolvedSymbols: [String] {
        [
            "kFigCaptureSourceAttributeKey_LocalizedName",
            "kFigCaptureSourceAttributeKey_MaxFrameRate",
            "kFigCaptureSourceAttributeKey_MinFrameRate",
            "kFigCaptureSourceProperty_Attributes",
            "kFigCaptureSourceProperty_AttributesDictionary",
        ]
    }

    // MARK: Functions

    @Test(arguments: ["geistcam_computePortraitDataOutputPlan", "geistcam_imageByApplyingTransformPlan"])
    func cameraTransform_BundledDylib_DefinesRenderingSymbols(symbol: String) throws {
        let output = try nmOutput(for: GeistCamShimBundled.dylibPath)

        #expect(output.split(separator: "\n").contains {
            $0.contains("(__TEXT,__text)") && containsSymbol("_\(symbol)", in: String($0))
        })
    }

    @Test(arguments: [
        "AudioComponentInstanceNew", "AudioComponentInstanceDispose", "AudioUnitSetProperty",
        "AudioUnitInitialize", "AudioOutputUnitStart", "AudioOutputUnitStop", "AudioUnitRender",
    ])
    func audioInput_BundledDylib_DefinesCaptureAndBufferSymbols(interposed: String) throws {
        let output = try nmOutput(for: GeistCamShimBundled.dylibPath)
        let lines = output.split(separator: "\n").map(String.init)

        #expect(lines.contains { $0.contains("(__TEXT,__text)") && containsSymbol("_audioInputEnable", in: $0) })
        #expect(lines.contains { $0.contains("(__TEXT,__text)") && containsSymbol("_geistAudioInputBufferRender", in: $0) })
        #expect(lines.contains { containsSymbol("_interpose_\(interposed)", in: $0) })
    }

    @Test func removedCMCaptureSymbols_bundledDylib_areWeakOrDynamicallyResolved() throws {
        let output = try nmOutput(for: GeistCamShimBundled.dylibPath)
        let lines = output.split(separator: "\n").map(String.init)
        let importLine = try #require(lines.first {
            $0.contains("(undefined)") && containsSymbol("_FigCaptureSourceCopySources", in: $0)
        })

        #expect(importLine.contains("weak external"))
        #expect(lines.contains { containsSymbol("__geistcam_interpose_FigCaptureSourceCopySources", in: $0) })
        for symbol in dynamicallyResolvedSymbols {
            #expect(!lines.contains { $0.contains("(undefined)") && containsSymbol("_\(symbol)", in: $0) })
        }
    }

    private func nmOutput(for path: String) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["nm", "-m", path]
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self)
    }

    private func containsSymbol(_ symbol: String, in line: String) -> Bool {
        line.split(whereSeparator: { $0.isWhitespace }).contains(Substring(symbol))
    }
}
