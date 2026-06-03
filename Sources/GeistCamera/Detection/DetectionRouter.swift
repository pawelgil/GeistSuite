import CoreMedia
import CoreVideo
import Foundation

final class DetectionRouter: VideoFrameSink {
    private let slot: UInt32
    private let downstream: any VideoFrameSink
    private let demand: DemandRegistry
    private let detector: any HostDetecting

    init(slot: UInt32,
         downstream: any VideoFrameSink,
         demand: DemandRegistry,
         detector: any HostDetecting) {
        self.slot = slot
        self.downstream = downstream
        self.demand = demand
        self.detector = detector
    }

    func sendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) {
        downstream.sendVideo(pixelBuffer, pts: pts, duration: duration)
        let d = demand.demand(slot: slot)
        if !d.isEmpty {
            detector.process(slot: slot, pixelBuffer: pixelBuffer, demand: d)
        }
    }
}
