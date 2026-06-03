import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import Synchronization
import Vision
import GeistKit

protocol HostDetecting: AnyObject, Sendable {
    func process(slot: UInt32, pixelBuffer: CVPixelBuffer, demand: SlotDemand)
}

final class HostDetector: HostDetecting, Sendable {
    private static let detectionInterval: CFTimeInterval = 0.25

    private struct SlotState {
        var lastDispatch: CFTimeInterval = 0
        var inFlight: Bool = false
    }

    private let state = Mutex<[UInt32: SlotState]>([:])
    private let resultsHandler: @Sendable (WireMetadataResults) -> Void

    init(resultsHandler: @escaping @Sendable (WireMetadataResults) -> Void) {
        self.resultsHandler = resultsHandler
    }

    func process(slot: UInt32, pixelBuffer: CVPixelBuffer, demand: SlotDemand) {
        if demand.isEmpty { return }
        let now = CACurrentMediaTime()
        let shouldRun = state.withLock { all -> Bool in
            var s = all[slot] ?? SlotState()
            if s.inFlight { return false }
            if now - s.lastDispatch < Self.detectionInterval { return false }
            s.lastDispatch = now
            s.inFlight = true
            all[slot] = s
            return true
        }
        guard shouldRun else { return }

        let wrapped = UncheckedBuffer(value: pixelBuffer)
        Task.detached(priority: .userInitiated) { [self] in
            let objects = detect(pixelBuffer: wrapped.value, demand: demand)
            resultsHandler(WireMetadataResults(slot: slot, objects: objects))
            state.withLock { $0[slot]?.inFlight = false }
        }
    }

    private func detect(pixelBuffer: CVPixelBuffer, demand: SlotDemand) -> [WireMetadataObject] {
        var requests: [VNRequest] = []
        if demand.wantsQR {
            let r = VNDetectBarcodesRequest()
            r.symbologies = [.qr]
            requests.append(r)
        }
        if demand.wantsFace {
            requests.append(VNDetectFaceRectanglesRequest())
        }
        if requests.isEmpty { return [] }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .up,
                                            options: [:])
        do {
            try handler.perform(requests)
        } catch {
            log.warn("detection failed: \(error)")
            return []
        }

        var out: [WireMetadataObject] = []
        for r in requests {
            switch r {
            case let qr as VNDetectBarcodesRequest:
                for obs in qr.results ?? [] {
                    out.append(makeQR(obs))
                }
            case let face as VNDetectFaceRectanglesRequest:
                var faceID: Int32 = 1
                for obs in face.results ?? [] {
                    out.append(makeFace(obs, id: faceID))
                    faceID += 1
                }
            default:
                break
            }
        }
        return out
    }

    private func avfBounds(from box: CGRect) -> (x: Float, y: Float, w: Float, h: Float) {
        let y = 1.0 - box.origin.y - box.size.height
        return (Float(box.origin.x), Float(y), Float(box.size.width), Float(box.size.height))
    }

    private func makeQR(_ obs: VNBarcodeObservation) -> WireMetadataObject {
        let b = avfBounds(from: obs.boundingBox)
        return WireMetadataObject(
            kind: .qr, faceID: -1,
            boundsX: b.x, boundsY: b.y, boundsW: b.w, boundsH: b.h,
            stringValue: obs.payloadStringValue
        )
    }

    private func makeFace(_ obs: VNFaceObservation, id: Int32) -> WireMetadataObject {
        let b = avfBounds(from: obs.boundingBox)
        return WireMetadataObject(
            kind: .face, faceID: id,
            boundsX: b.x, boundsY: b.y, boundsW: b.w, boundsH: b.h,
            stringValue: nil
        )
    }
}
