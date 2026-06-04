import CoreSimulatorPrivate
import Darwin
import Foundation
import Security
import SecurityPrivate

// §0 spike from NO_SHELLOUT_RESEARCH.md. Stages a broadcast appex with an
// in-process SecCodeSigner re-sign and spawns it non-standalone via
// SimDevice spawnWithPath. Success ⇒ launchd_sim accepts an adhoc
// SecCodeSigner-produced signature.

func die(_ step: String, _ message: String) -> Never {
    print("[FAIL] [\(step)] \(message)")
    exit(1)
}

func log(_ step: String, _ message: String) {
    print("[\(step)] \(message)")
}

guard CommandLine.arguments.count >= 4 else {
    print("usage: recode-spike <sim-udid> <host-bundle-id> <ext-shim-dylib-path>")
    exit(2)
}
let simUDID = CommandLine.arguments[1]
let hostBundleID = CommandLine.arguments[2]
let shimDylib = CommandLine.arguments[3]
guard FileManager.default.fileExists(atPath: shimDylib) else {
    die("args", "ext-shim dylib not found at \(shimDylib)")
}

// MARK: - 1. Resolve SimDevice

log("1/7", "Resolving SimDevice for UDID \(simUDID) ...")
guard NSClassFromString("SimServiceContext") != nil else {
    die("1/7", "SimServiceContext class missing — CoreSimulator.framework didn't load")
}
let xsel = Process()
xsel.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
xsel.arguments = ["-p"]
let xselOut = Pipe()
xsel.standardOutput = xselOut
xsel.standardError = Pipe()
try xsel.run()
xsel.waitUntilExit()
let developerDir = String(
    decoding: xselOut.fileHandleForReading.readDataToEndOfFile(),
    as: UTF8.self
).trimmingCharacters(in: .whitespacesAndNewlines)
log("1/7", "Developer dir: \(developerDir)")

let context: SimServiceContext
do { context = try SimServiceContext(forDeveloperDir: developerDir) }
catch { die("1/7", "SimServiceContext init failed: \(error)") }

let deviceSet: SimDeviceSet
do { deviceSet = try context.defaultDeviceSet() }
catch { die("1/7", "defaultDeviceSet failed: \(error)") }

guard let devices = deviceSet.devices as? [SimDevice] else {
    die("1/7", "deviceSet.devices not [SimDevice]")
}
guard let device = devices.first(where: {
    $0.udid?.uuidString.lowercased() == simUDID.lowercased()
}) else {
    die("1/7", "no booted SimDevice with UDID \(simUDID)")
}
log("1/7", "Device: \(device.name ?? "?") state=\(device.state)")
guard device.state == 3 else {
    die("1/7", "device state \(device.state) is not Booted (3)")
}

// MARK: - 2. installedAppsWithError → host app path

log("2/7", "Calling installedAppsWithError ...")
let installed: [String: Any]
do {
    let raw = try device.installedApps()
    guard let dict = raw as? [String: Any] else {
        die("2/7", "installedApps returned \(type(of: raw)), not [String: Any]")
    }
    installed = dict
} catch {
    die("2/7", "installedApps threw: \(error)")
}
log("2/7", "\(installed.count) apps installed.")
guard let hostApp = installed[hostBundleID] as? [String: Any] else {
    die("2/7", "host \(hostBundleID) not installed (have \(installed.count) others)")
}
guard let hostPath = hostApp["Path"] as? String else {
    die("2/7", "host app entry missing 'Path' key. Keys: \(hostApp.keys.sorted())")
}
log("2/7", "Host path: \(hostPath)")

// MARK: - 3. Discover broadcast appex inside host

log("3/7", "Scanning \(hostPath)/PlugIns/ for broadcast appex ...")
let plugins = (hostPath as NSString).appendingPathComponent("PlugIns")
let entries = (try? FileManager.default.contentsOfDirectory(atPath: plugins)) ?? []
var broadcastAppex: String?
for entry in entries where entry.hasSuffix(".appex") {
    let appexPath = (plugins as NSString).appendingPathComponent(entry)
    let plistPath = (appexPath as NSString).appendingPathComponent("Info.plist")
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let ext = plist["NSExtension"] as? [String: Any],
          let pointID = ext["NSExtensionPointIdentifier"] as? String else { continue }
    if pointID == "com.apple.broadcast-services-upload" {
        broadcastAppex = appexPath
        break
    }
}
guard let broadcastAppex else {
    die("3/7", "no broadcast extension appex inside \(plugins)")
}
log("3/7", "Found: \(broadcastAppex)")

// MARK: - 4. Copy + patch Info.plist CFBundlePackageType

log("4/7", "Copying to /tmp and patching CFBundlePackageType ...")
let stagedAppex = "/tmp/recode-spike-\(UUID().uuidString).appex"
do { try FileManager.default.copyItem(atPath: broadcastAppex, toPath: stagedAppex) }
catch { die("4/7", "copyItem failed: \(error)") }
log("4/7", "Staged at: \(stagedAppex)")

let stagedPlist = (stagedAppex as NSString).appendingPathComponent("Info.plist")
let plistData = try Data(contentsOf: URL(fileURLWithPath: stagedPlist))
guard var plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
    die("4/7", "Info.plist not a dict")
}
plist["CFBundlePackageType"] = "APPL"
guard let executableName = plist["CFBundleExecutable"] as? String else {
    die("4/7", "Info.plist missing CFBundleExecutable")
}
let patched = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
try patched.write(to: URL(fileURLWithPath: stagedPlist))
let binaryPath = (stagedAppex as NSString).appendingPathComponent(executableName)
log("4/7", "Binary: \(binaryPath)")

// MARK: - 5. Read entitlements via SecCodeCopySigningInformation

log("5/7", "Reading embedded entitlements ...")
var staticCode: SecStaticCode?
let createStatus = SecStaticCodeCreateWithPath(
    URL(fileURLWithPath: stagedAppex) as CFURL,
    SecCSFlags(rawValue: 0),
    &staticCode
)
guard createStatus == errSecSuccess, let code = staticCode else {
    die("5/7", "SecStaticCodeCreateWithPath status=\(createStatus)")
}

var info: CFDictionary?
let infoStatus = SecCodeCopySigningInformation(
    code,
    SecCSFlags(rawValue: kSecCSRequirementInformation),
    &info
)
guard infoStatus == errSecSuccess, let infoDict = info as? [String: Any] else {
    die("5/7", "SecCodeCopySigningInformation status=\(infoStatus)")
}

var entitlements: [String: Any] = (infoDict["entitlements-dict"] as? [String: Any]) ?? [:]
log("5/7", "Existing entitlement keys: \(entitlements.keys.sorted().joined(separator: ", "))")

let removed = entitlements.removeValue(forKey: "application-identifier")
if let removed = removed as? String {
    log("5/7", "Scrubbed application-identifier='\(removed)'")
} else {
    log("5/7", "(no application-identifier present)")
}

let scrubbedData = try PropertyListSerialization.data(
    fromPropertyList: entitlements,
    format: .xml,
    options: 0
)

// MARK: - 6. Scrub + re-sign in place via SecCodeSigner

// Synthesize a team-prefixed application-identifier (the entitlement
// production code must scrub) on top of whatever was embedded. Then drop it.
// This exercises the same staging path the no-shellout refactor would take.
var synthetic: [String: Any] = entitlements
synthetic["application-identifier"] = "ABCDE12345.com.geistcast.testapp.broadcast"
let originalCount = synthetic.count
synthetic.removeValue(forKey: "application-identifier")
log("6/7", "Scrubbed application-identifier (was \(originalCount) keys → \(synthetic.count))")

let entitlementsXML = try PropertyListSerialization.data(
    fromPropertyList: synthetic,
    format: .xml,
    options: 0
)

// CRITICAL: SecCodeSigner's kSecCodeSignerEntitlements expects the wrapped
// CSMAGIC_EMBEDDED_ENTITLEMENTS blob format (0xFADE7171 + big-endian uint32
// length + XML plist payload). Passing raw XML plist data produces SIGBUS
// inside AddSignatureWithErrors. This is NOT documented in any Apple header
// or SecCodeSigner sample we could find — discovered empirically by this
// spike on macOS 26.4 / Xcode 26.4.1.
let CSMAGIC_EMBEDDED_ENTITLEMENTS: UInt32 = 0xFADE7171
var wrappedEntitlements = Data()
withUnsafeBytes(of: CSMAGIC_EMBEDDED_ENTITLEMENTS.bigEndian) {
    wrappedEntitlements.append(contentsOf: $0)
}
withUnsafeBytes(of: UInt32(8 + entitlementsXML.count).bigEndian) {
    wrappedEntitlements.append(contentsOf: $0)
}
wrappedEntitlements.append(entitlementsXML)
log("6/7", "Entitlements: \(entitlementsXML.count)-byte plist wrapped to \(wrappedEntitlements.count) bytes (CSMAGIC=0xFADE7171)")

let signerParams: [CFString: Any] = [
    kSecCodeSignerIdentity: kCFNull,
    kSecCodeSignerEntitlements: wrappedEntitlements as NSData,
]

var signer: SecCodeSignerRef?
let signerStatus = SecCodeSignerCreate(signerParams as CFDictionary, SecCSFlags(rawValue: 0), &signer)
guard signerStatus == errSecSuccess, let signerRef = signer else {
    die("6/7", "SecCodeSignerCreate status=\(signerStatus)")
}
log("6/7", "SecCodeSignerCreate OK (adhoc)")

var signError: Unmanaged<CFError>?
let signStatus = SecCodeSignerAddSignatureWithErrors(signerRef, code, SecCSFlags(rawValue: 0), &signError)
if signStatus != errSecSuccess {
    let err = signError?.takeRetainedValue()
    die("6/7", "AddSignatureWithErrors status=\(signStatus): \(String(describing: err))")
}
log("6/7", "Re-signed adhoc — bundle has fresh SecCodeSigner signature")

// Verify the new signature is internally consistent
var verifiedCode: SecStaticCode?
_ = SecStaticCodeCreateWithPath(
    URL(fileURLWithPath: stagedAppex) as CFURL,
    SecCSFlags(rawValue: 0),
    &verifiedCode
)
if let verified = verifiedCode {
    let verifyStatus = SecStaticCodeCheckValidity(verified, SecCSFlags(rawValue: 0), nil)
    log("6/7", "Self-validation: \(verifyStatus == errSecSuccess ? "OK" : "FAILED with status \(verifyStatus)")")
}

// MARK: - 7. Spawn via SimDevice spawnWithPath (non-standalone), wait for HELLO

log("7/7", "Setting up control socket so the shim can prove it loaded ...")
let controlSocketPath = "/tmp/recode-spike-ctrl-\(UUID().uuidString).sock"
unlink(controlSocketPath)
let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
guard listenFD >= 0 else { die("7/7", "socket() failed errno=\(errno)") }
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
    ptr.withMemoryRebound(to: CChar.self, capacity: 104) { cptr in
        _ = controlSocketPath.withCString { src in strcpy(cptr, src) }
    }
}
let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
let bindOK = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
        bind(listenFD, sptr, addrLen)
    }
}
guard bindOK == 0 else { die("7/7", "bind() failed errno=\(errno)") }
guard listen(listenFD, 1) == 0 else { die("7/7", "listen() failed errno=\(errno)") }
log("7/7", "Listening on \(controlSocketPath)")

let childOutPath = "/tmp/recode-spike-child-\(UUID().uuidString).log"
let childOutFD = open(childOutPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
guard childOutFD >= 0 else { die("7/7", "failed to open \(childOutPath)") }
defer { close(childOutFD) }
log("7/7", "Child stdout/stderr capture: \(childOutPath)")

log("7/7", "Spawning \(binaryPath) non-standalone via SimDevice ...")
let options: [String: Any] = [
    "arguments": [binaryPath],
    "environment": [
        "DYLD_INSERT_LIBRARIES": shimDylib,
        "GEISTCAST_SOCKET": controlSocketPath,
    ],
    "stdin": 0,
    "stdout": Int(childOutFD),
    "stderr": Int(childOutFD),
    "standalone": kCFBooleanFalse as Any,
]

let exited = DispatchSemaphore(value: 0)
nonisolated(unsafe) var exitStatus: Int32 = -999

var pidValue: Int32 = 0
var spawnErr: AnyObject?
let ok = device.spawn(
    withPath: binaryPath,
    options: options,
    terminationQueue: DispatchQueue.global(qos: .utility),
    terminationHandler: { (status: Int32) in
        exitStatus = status
        exited.signal()
    } as @convention(block) (Int32) -> Void,
    pid: &pidValue,
    error: &spawnErr
)
guard ok else {
    let msg = (spawnErr as? NSError)?.localizedDescription ?? "\(String(describing: spawnErr))"
    die("7/7", "spawnWithPath returned NO: \(msg)")
}
log("7/7", "Spawned PID \(pidValue)")

// Accept the shim's connection (or time out) on a background queue
let helloReceived = DispatchSemaphore(value: 0)
nonisolated(unsafe) var helloLine: String?
DispatchQueue.global(qos: .userInitiated).async {
    var clientAddr = sockaddr()
    var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
    let clientFD = accept(listenFD, &clientAddr, &clientLen)
    guard clientFD >= 0 else {
        print("[accept] failed errno=\(errno)")
        helloReceived.signal()
        return
    }
    var lineBytes = [UInt8]()
    var buf = [UInt8](repeating: 0, count: 1024)
    outer: while true {
        let n = read(clientFD, &buf, buf.count)
        if n <= 0 { break }
        for i in 0..<n {
            if buf[Int(i)] == 0x0a {
                helloLine = String(bytes: lineBytes, encoding: .utf8)
                close(clientFD)
                helloReceived.signal()
                break outer
            }
            lineBytes.append(buf[Int(i)])
        }
    }
}

func dumpChildOutput() {
    let data = (try? Data(contentsOf: URL(fileURLWithPath: childOutPath))) ?? Data()
    let text = String(decoding: data, as: UTF8.self)
    print("--- child stdout/stderr (\(data.count) bytes from \(childOutPath)) ---")
    print(text.isEmpty ? "(empty)" : text)
    print("--- end child output ---")
}

// Race: hello arrival vs child exit vs 10s timeout
let deadline = DispatchTime.now() + 10
let helloResult = helloReceived.wait(timeout: deadline)
print()

if helloResult == .success, let line = helloLine {
    print("✅ SUCCESS: shim sent HELLO on the control socket.")
    print("   Message: \(line)")
    print()
    print("   This means the full chain works end-to-end:")
    print("   - SecCodeSigner-produced adhoc signature accepted by launchd_sim")
    print("   - SimDevice.spawnWithPath spawned the appex non-standalone")
    print("   - DYLD_INSERT_LIBRARIES took effect; extension shim loaded")
    print("   - Shim constructor ran; lifecycle driver connected to our socket")
    print()
    print("   The §Open question from NO_SHELLOUT_RESEARCH.md is closed.")
    kill(pidValue, SIGKILL)
    _ = exited.wait(timeout: .now() + 2)
} else {
    let exitWait = exited.wait(timeout: .now() + 2)
    if exitWait == .success {
        print("❌ FAILURE: child exited with raw wait-status \(exitStatus) before sending HELLO.")
        let exitCode = (exitStatus >> 8) & 0xff
        let signaled = (exitStatus & 0x7f) != 0
        print("    Decoded: exitCode=\(exitCode) signaled=\(signaled)")
    } else {
        print("⚠️  TIMEOUT: 10s elapsed; no HELLO and child still running.")
        kill(pidValue, SIGKILL)
    }
    dumpChildOutput()
    exit(3)
}
