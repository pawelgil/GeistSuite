import Foundation
import GeistKit
import Security
import SecurityPrivate

struct StagedAppex: Sendable, Equatable {
    let binaryPath: String
}

protocol AppexStaging: Sendable {
    func stage(appexAt sourcePath: String) async throws -> StagedAppex
}

protocol BundleResigning: Sendable {
    /// Re-signs `bundlePath` adhoc, replacing the existing signature. Reads
    /// the bundle's current embedded entitlements, drops `scrubbingKey` from
    /// them, and writes the scrubbed plist back in the
    /// `CSMAGIC_EMBEDDED_ENTITLEMENTS`-wrapped form required by `SecCodeSigner`.
    func resign(bundleAt bundlePath: String, scrubbingKey: String) throws
}

struct AppexStager: AppexStaging, Sendable {

    enum StagerError: Error, Equatable {
        case missingExecutableName(plistPath: String)
        case malformedPlist(plistPath: String)
    }

    private let fileSystem: any FileSystem
    private let resigner: any BundleResigning

    init(fileSystem: any FileSystem = LiveFileSystem(),
         resigner: any BundleResigning = LiveBundleResigner()) {
        self.fileSystem = fileSystem
        self.resigner = resigner
    }

    func stage(appexAt sourcePath: String) async throws -> StagedAppex {
        let stagedAppex = "/tmp/geistcast-staged-appex-\(UUID().uuidString).appex"
        try fileSystem.copyItem(atPath: sourcePath, toPath: stagedAppex)
        let plist = try patchPackageType(at: stagedAppex)
        guard let executableName = plist["CFBundleExecutable"] as? String else {
            throw StagerError.missingExecutableName(plistPath: "\(stagedAppex)/Info.plist")
        }
        let binaryPath = "\(stagedAppex)/\(executableName)"
        try resigner.resign(bundleAt: stagedAppex, scrubbingKey: "application-identifier")
        return StagedAppex(binaryPath: binaryPath)
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

/// Adhoc re-signer that calls into the Security framework SPI directly.
/// Replaces the `lipo -thin` + `xcrun segedit -extract __entitlements` +
/// `codesign --force --sign -` shellout chain. The bundle's existing
/// signature is read (entitlements extracted from the embedded blob),
/// `scrubbingKey` is dropped from the dict, and the result is wrapped
/// with `CSMAGIC_EMBEDDED_ENTITLEMENTS` (0xFADE7171 + big-endian length +
/// XML plist) before passing to `SecCodeSigner` — that wrapping is
/// required and is not documented in any Apple-shipped header.
struct LiveBundleResigner: BundleResigning {

    enum ResignerError: Error {
        case staticCodeCreateFailed(OSStatus)
        case signingInformationFailed(OSStatus)
        case signerCreateFailed(OSStatus)
        case signFailed(status: OSStatus, error: CFError?)
    }

    private static let csMagicEmbeddedEntitlements: UInt32 = 0xFADE7171

    func resign(bundleAt bundlePath: String, scrubbingKey: String) throws {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            URL(fileURLWithPath: bundlePath) as CFURL,
            SecCSFlags(rawValue: 0),
            &staticCode
        )
        guard createStatus == errSecSuccess, let code = staticCode else {
            throw ResignerError.staticCodeCreateFailed(createStatus)
        }

        var info: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSRequirementInformation),
            &info
        )
        guard infoStatus == errSecSuccess, let infoDict = info as? [String: Any] else {
            throw ResignerError.signingInformationFailed(infoStatus)
        }

        var entitlements: [String: Any] = (infoDict["entitlements-dict"] as? [String: Any]) ?? [:]
        entitlements.removeValue(forKey: scrubbingKey)

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: entitlements,
            format: .xml,
            options: 0
        )
        let wrapped = Self.wrapEntitlements(plistData)

        let signerParams: [CFString: Any] = [
            kSecCodeSignerIdentity: kCFNull,
            kSecCodeSignerEntitlements: wrapped as NSData,
        ]

        var signer: SecCodeSignerRef?
        let signerStatus = SecCodeSignerCreate(
            signerParams as CFDictionary,
            SecCSFlags(rawValue: 0),
            &signer
        )
        guard signerStatus == errSecSuccess, let signerRef = signer else {
            throw ResignerError.signerCreateFailed(signerStatus)
        }

        var cfError: Unmanaged<CFError>?
        let signStatus = SecCodeSignerAddSignatureWithErrors(
            signerRef,
            code,
            SecCSFlags(rawValue: 0),
            &cfError
        )
        if signStatus != errSecSuccess {
            throw ResignerError.signFailed(
                status: signStatus,
                error: cfError?.takeRetainedValue()
            )
        }
    }

    private static func wrapEntitlements(_ xml: Data) -> Data {
        var blob = Data()
        withUnsafeBytes(of: csMagicEmbeddedEntitlements.bigEndian) { blob.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(8 + xml.count).bigEndian) { blob.append(contentsOf: $0) }
        blob.append(xml)
        return blob
    }
}
