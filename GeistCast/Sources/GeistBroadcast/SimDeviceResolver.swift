import CoreSimulatorPrivate
import Foundation
import GeistKit

/// Resolves a `SimDevice` for a UDID by walking a `SimDeviceSet`. Used by the
/// no-shellout staging/spawn pipeline in place of `xcrun simctl --set <path>`.
struct SimDeviceResolver: Sendable {

    enum ResolverError: Error, Equatable {
        case coreSimulatorUnavailable
        case developerDirUnavailable
        case serviceContextInitFailed(String)
        case deviceSetInitFailed(String)
        case deviceNotFound(udid: String)
    }

    private let developerDirResolver: any DeveloperDirResolving

    init(developerDirResolver: any DeveloperDirResolving = LiveDeveloperDirResolver()) {
        self.developerDirResolver = developerDirResolver
    }

    func resolve(udid: UUID, simctlSetPath: String?) throws -> SimDevice {
        guard NSClassFromString("SimServiceContext") != nil else {
            throw ResolverError.coreSimulatorUnavailable
        }
        guard let developerDir = developerDirResolver.resolve() else {
            throw ResolverError.developerDirUnavailable
        }
        let context: SimServiceContext
        do { context = try SimServiceContext(forDeveloperDir: developerDir) }
        catch { throw ResolverError.serviceContextInitFailed(String(describing: error)) }

        let deviceSet: SimDeviceSet
        do {
            if let simctlSetPath {
                deviceSet = try context.deviceSet(withPath: simctlSetPath)
            } else {
                deviceSet = try context.defaultDeviceSet()
            }
        } catch {
            throw ResolverError.deviceSetInitFailed(String(describing: error))
        }

        let target = udid.uuidString.lowercased()
        let devices = (deviceSet.devices as? [SimDevice]) ?? []
        guard let device = devices.first(where: {
            $0.udid?.uuidString.lowercased() == target
        }) else {
            throw ResolverError.deviceNotFound(udid: udid.uuidString)
        }
        return device
    }
}
