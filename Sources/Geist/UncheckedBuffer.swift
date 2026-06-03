import AVFoundation
import CoreVideo

// CVPixelBuffer is a thread-safe CFType (atomic refcount; buffer data access
// gated by CVPixelBufferLockBaseAddress). Safe to transfer across isolation
// boundaries when the producer hands ownership and does not mutate afterward.
struct UncheckedBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}

// AVAudioPCMBuffer is an NSObject; its byte buffer is mutable but the producer
// hands off ownership at the moment of sending and does not mutate afterward.
struct UncheckedPCM: @unchecked Sendable {
    let value: AVAudioPCMBuffer
}
