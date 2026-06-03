internal import CoreSimulatorPrivate
import Foundation
import IOSurface

enum SurfaceLocator {
    static let mainScreenID: UInt32 = 1

    /// Returns `nil` when the device has no IO ports (e.g. not booted yet).
    static func mainScreen(of device: SimDevice) -> (any SimScreen)? {
        guard let io = device.io else { return nil }
        let descriptorSel = NSSelectorFromString("descriptor")

        for element in io.ioPorts {
            guard let port = element as? NSObject,
                  port.responds(to: descriptorSel),
                  let desc = port.perform(descriptorSel)?.takeUnretainedValue() as? SimScreen,
                  desc.screenProperties?.screenID == mainScreenID
            else { continue }
            return desc
        }
        return nil
    }

    /// Prefers the device-shaped mask (`screenID == 1`); falls back to the
    /// first port that exposes a framebuffer.
    static func primarySurface(of device: SimDevice) -> IOSurface? {
        guard let io = device.io else { return nil }
        let descriptorSel = NSSelectorFromString("descriptor")
        let surfaceSel = NSSelectorFromString("framebufferSurface")

        for element in io.ioPorts {
            guard let port = element as? NSObject, port.responds(to: descriptorSel),
                  let desc = port.perform(descriptorSel)?.takeUnretainedValue() as? NSObject,
                  let screen = desc as? SimScreen,
                  screen.screenProperties?.screenID == mainScreenID,
                  desc.responds(to: surfaceSel),
                  let surface = desc.perform(surfaceSel)?.takeUnretainedValue() as? IOSurface
            else { continue }
            return surface
        }

        for element in io.ioPorts {
            guard let port = element as? NSObject, port.responds(to: descriptorSel),
                  let desc = port.perform(descriptorSel)?.takeUnretainedValue() as? NSObject,
                  desc.responds(to: surfaceSel),
                  let surface = desc.perform(surfaceSel)?.takeUnretainedValue() as? IOSurface
            else { continue }
            return surface
        }
        return nil
    }
}
