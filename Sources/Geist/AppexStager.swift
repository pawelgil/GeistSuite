import Foundation

struct StagedAppex: Sendable, Equatable {
    let binaryPath: String
}

protocol AppexStaging: Sendable {
    func stage(appexAt sourcePath: String) async throws -> StagedAppex
}

struct AppexStager: AppexStaging, Sendable {

    enum StagerError: Error, Equatable {
        case missingExecutableName(plistPath: String)
        case malformedPlist(plistPath: String)
    }

    private let fileSystem: any FileSystem
    private let process: any ProcessRunner

    init(fileSystem: any FileSystem = LiveFileSystem(),
         process: any ProcessRunner = LiveProcessRunner()) {
        self.fileSystem = fileSystem
        self.process = process
    }

    func stage(appexAt sourcePath: String) async throws -> StagedAppex {
        let stagedAppex = "/tmp/geistcast-staged-appex-\(UUID().uuidString).appex"
        try fileSystem.copyItem(atPath: sourcePath, toPath: stagedAppex)
        let plist = try patchPackageType(at: stagedAppex)
        guard let executableName = plist["CFBundleExecutable"] as? String else {
            throw StagerError.missingExecutableName(plistPath: "\(stagedAppex)/Info.plist")
        }
        let binaryPath = "\(stagedAppex)/\(executableName)"
        // Patching Info.plist invalidates _CodeSignature/CodeResources, which
        // launchd_sim refuses to spawn. Re-codesign the bundle, preserving the
        // binary's embedded entitlements.
        try await recodesign(appexPath: stagedAppex, binaryPath: binaryPath)
        return StagedAppex(binaryPath: binaryPath)
    }

    private func recodesign(appexPath: String, binaryPath: String) async throws {
        // Temp files live OUTSIDE the bundle so `codesign --force` doesn't seal
        // them into _CodeSignature/CodeResources (which would then complain
        // "sealed resource missing" once we clean them up).
        let tmpBase = "/tmp/geistcast-recodesign-\(UUID().uuidString)"
        let thinBinary = "\(tmpBase).bin"
        let entitlementsFile = "\(tmpBase).entitlements.plist"

        // Thin the fat binary so segedit can operate on it.
        _ = try await process.run(ProcessInvocation(
            executable: "/usr/bin/lipo",
            arguments: ["-thin", "arm64", binaryPath, "-output", thinBinary],
            environment: [:]
        ))

        _ = try await process.run(ProcessInvocation(
            executable: "/usr/bin/xcrun",
            arguments: ["segedit", thinBinary,
                        "-extract", "__TEXT", "__entitlements", entitlementsFile],
            environment: [:]
        ))

        // xcodebuild bakes a team-prefixed `application-identifier` even for
        // adhoc signing; launchd_sim refuses to spawn with that mismatch.
        // Failures here are recoverable (codesign will surface its own error
        // downstream), so just log and continue rather than throwing.
        scrubEntitlements(at: entitlementsFile)

        _ = try await process.run(ProcessInvocation(
            executable: "/usr/bin/codesign",
            arguments: ["--force", "--sign", "-",
                        "--entitlements", entitlementsFile,
                        appexPath],
            environment: [:]
        ))
    }

    private func scrubEntitlements(at entitlementsFile: String) {
        do {
            let entData = try fileSystem.contentsOfFile(atPath: entitlementsFile)
            guard var plist = try PropertyListSerialization.propertyList(
                from: entData, format: nil
            ) as? [String: Any] else {
                Log.warn("AppexStager: entitlements scrub skipped — plist not a dict")
                return
            }
            plist.removeValue(forKey: "application-identifier")
            let cleaned = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )
            try fileSystem.write(cleaned, toPath: entitlementsFile)
        } catch {
            Log.warn("AppexStager: entitlements scrub failed: \(error)")
        }
    }

    private func patchPackageType(at appexPath: String) throws -> [String: Any] {
        let plistPath = "\(appexPath)/Info.plist"
        let plistData = try fileSystem.contentsOfFile(atPath: plistPath)
        guard var plist = try PropertyListSerialization.propertyList(
            from: plistData, format: nil
        ) as? [String: Any] else {
            throw StagerError.malformedPlist(plistPath: plistPath)
        }
        plist["CFBundlePackageType"] = "APPL"
        let patched = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try fileSystem.write(patched, toPath: plistPath)
        return plist
    }
}
