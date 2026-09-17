import AVFoundation
import CoreMedia

/// Reports synchronous admission to the bounded outbound queue, not downstream delivery.
public protocol AudioFrameAdmissionReporting: AudioFrameSink {
    func sendAudioReportingAdmission(
        _ samples: AVAudioPCMBuffer,
        pts: CMTime
    ) -> AudioFrameAdmission
}
