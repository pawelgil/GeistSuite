import CoreSimulatorPrivate
import Foundation
import GeistKit

/// Resolves a `SimDevice` for a UDID by walking a `SimDeviceSet`. Used by the
/// no-shellout staging/spawn pipeline in place of `xcrun simctl --set <path>`.
enum SimDeviceResolver {

    enum ResolverError: Error, Equatable {
        case coreSimulatorUnavailable
        case developerDirUnavailable
        case serviceContextInitFailed(String)
        case deviceSetInitFailed(String)
        case deviceNotFound(udid: String)
    }

    static func resolve(udid: UUID, simctlSetPath: String?) throws -> SimDevice {
        guard NSClassFromString("SimServiceContext") != nil else {
            throw ResolverError.coreSimulatorUnavailable
        }
        guard let developerDir = currentDeveloperDir() else {
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

    private static func currentDeveloperDir() -> String? {
        if let env = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !env.isEmpty {
            return env
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
