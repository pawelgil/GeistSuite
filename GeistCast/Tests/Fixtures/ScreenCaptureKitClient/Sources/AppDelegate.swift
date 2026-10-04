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
    private var completedCaptures = 0
    private var restarting = false
    private var previousTimestamp = CMTime.invalid
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
        var copy = configuration
        copy.showsMicrophoneControl = false
        guard configuration.showsMicrophoneControl else {
            Self.report("SCK_CONFIGURATION_COPY_ERROR")
            return true
        }
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
        var streamPickerConfiguration = SCContentSharingPickerConfiguration()
        streamPickerConfiguration.showsMicrophoneControl = false
        SCContentSharingPicker.shared.setConfiguration(streamPickerConfiguration, for: capture)
        guard SCContentSharingPicker.shared.defaultConfiguration.showsMicrophoneControl else {
            Self.report("SCK_STREAM_CONFIGURATION_LEAK")
            return
        }
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
        _ capture: SCStream,
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
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let metadata = attachments.first,
              metadata[.status] as? Int == SCFrameStatus.complete.rawValue,
              let contentRect = metadata[.contentRect] as? NSDictionary,
              CGRect(dictionaryRepresentation: contentRect as CFDictionary) != nil,
              metadata[.scaleFactor] as? Double != nil
        else {
            Self.report("SCK_INVALID_METADATA")
            return
        }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard timestamp.isNumeric, timestamp > .zero,
              !previousTimestamp.isValid || timestamp >= previousTimestamp else {
            Self.report("SCK_INVALID_TIMESTAMP")
            return
        }
        previousTimestamp = timestamp
        guard !restarting else { return }
        completedCaptures += 1
        if completedCaptures == 3 {
            Self.report("SCK_FRAME_OK")
            return
        }
        restarting = true
        Task { @MainActor in
            do {
                try await capture.stopCapture()
                guard !capture.isCapturing else {
                    Self.report("SCK_STOP_ERROR")
                    return
                }
                restarting = false
                try await capture.startCapture()
            } catch {
                Self.report("SCK_RESTART_ERROR \(error)")
            }
        }
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
