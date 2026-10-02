@preconcurrency import ScreenCaptureKit
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate,
    @preconcurrency SCContentSharingPickerObserver,
    SCRecordingOutputDelegate,
    @preconcurrency SCStreamOutput
{
    // MARK: Properties

    private var stream: SCStream?
    private var clipBufferingOutput: SCClipBufferingOutput?
    private var expectedFrameSize: (width: Int, height: Int)?
    private var recordingEditor: SCRecordingEditor?
    private var recordingOutput: SCRecordingOutput?

    // MARK: Static Functions

    private nonisolated static func report(_ result: String) {
        print(result)
        guard let path = ProcessInfo.processInfo.environment["SCK_RESULT_PATH"] else { return }
        try? Data(result.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    // MARK: Functions

    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "screen.mp4")
        recordingOutput = SCRecordingOutput(
            configuration: recordingConfiguration,
            delegate: self
        )
        recordingEditor = SCRecordingEditor(url: recordingConfiguration.outputURL)
        clipBufferingOutput = SCClipBufferingOutput(delegate: nil)
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.showsMicrophoneControl = true
        picker.configuration = configuration
        picker.add(self)
        picker.isActive = true
        picker.presentForCurrentApplication()
        return true
    }

    func application(
        _: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options _: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    func contentSharingPicker(
        _: SCContentSharingPicker,
        didCancelFor _: SCStream?
    ) {}

    func contentSharingPicker(
        _: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for _: SCStream?
    ) {
        let configuration = SCStreamConfiguration()
        guard filter.contentRect.width > 0,
              filter.contentRect.height > 0,
              filter.pointPixelScale > 0,
              configuration.width > 0,
              configuration.height > 0
        else {
            Self.report("SCK_INVALID_GEOMETRY")
            return
        }
        let capture = SCStream(filter: filter, configuration: configuration, delegate: nil)
        guard let recordingOutput,
              rejectsUnsupported({ try capture.addRecordingOutput(recordingOutput) }),
              let clipBufferingOutput,
              rejectsUnsupported({ try capture.addClipBufferingOutput(clipBufferingOutput) })
        else {
            Self.report("SCK_UNSUPPORTED_API_ERROR")
            return
        }
        do {
            try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: nil)
            expectedFrameSize = (configuration.width, configuration.height)
            stream = capture
            capture.startCapture { error in
                if let error { Self.report("SCK_START_ERROR \(error)") }
            }
        } catch {
            Self.report("SCK_OUTPUT_ERROR \(error)")
        }
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Self.report("SCK_PICKER_ERROR \(error)")
    }

    func stream(
        _: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let expectedFrameSize,
              CVPixelBufferGetWidth(imageBuffer) == expectedFrameSize.width,
              CVPixelBufferGetHeight(imageBuffer) == expectedFrameSize.height
        else {
            Self.report("SCK_INVALID_FRAME")
            return
        }
        Self.report("SCK_FRAME_OK")
    }

    private func rejectsUnsupported(_ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            return false
        } catch {
            let error = error as NSError
            return error.domain == SCStreamErrorDomain && error.code == -3823
        }
    }
}
