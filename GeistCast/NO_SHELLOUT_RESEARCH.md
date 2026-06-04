# No-Shellout Research

Research notes for converting GeistCast's broadcast machinery from subprocess shell-outs (`simctl`, `codesign`, `lipo`, `segedit`, `pkill`) to a fully in-process implementation talking to **CoreSimulator directly**.

**Status:** research / evaluation. No code changed yet.
**Last updated:** 2026-06-03.
**Environment verified against:** Xcode 26.4.1, CoreSimulator `1051.50`, macOS 26.4 SDK.

---

## Why

Today the library silently depends on a handful of command-line tools being present and behaving a certain way at **runtime**. For a standalone menu-bar app that's tolerable; for a library that other apps import via SPM it's a landmine:

1. **Hidden runtime dependency.** `xcrun`/`simctl`/`codesign`/`lipo`/`segedit` must be on `PATH` and the right version. A consumer gets no compile-time signal that these are required.
2. **Fragility & latency.** Each broadcast involves several `Process` spawns, output parsing, and OpenStep-plist scraping.
3. **CoreSim-direct alignment.** The screen-capture half of this repo (`SimulatorScreenCapture`) already talks to CoreSimulator directly. The broadcast half should too.

The goal is that **the public API does not change** — `GeistBroadcastSession`, `broadcastCapableApps`, the delegate, etc. stay identical. The refactor is entirely internal, which is what makes the library frictionless to import.

---

## Current shell-outs (inventory)

All shell-outs funnel through `ProcessRunner`/`LiveProcessRunner`.

| Tool | Where | Purpose |
|---|---|---|
| `simctl get_app_container <udid> <bid> app` | `Sources/Lib/ExtensionDiscovery.swift` (`appContainerPath`) | Resolve a host app's installed bundle path |
| `simctl listapps <udid>` | `Sources/Lib/ExtensionDiscovery.swift` (`simctlListApps`) | Enumerate installed apps (OpenStep plist on stdout) |
| `lipo -thin arm64` | `Sources/Lib/AppexStager.swift` (`recodesign`) | Thin the fat appex binary so `segedit` can read it |
| `segedit -extract __TEXT __entitlements` | `Sources/Lib/AppexStager.swift` (`recodesign`) | Pull the appex's embedded entitlements out to a file |
| `codesign --force --sign - --entitlements …` | `Sources/Lib/AppexStager.swift` (`recodesign`) | Adhoc re-sign after patching `Info.plist` |
| `simctl spawn <udid> <stagedBinary>` | `Sources/Lib/AppexSpawner.swift` (`spawn`) | Launch the staged appex as a standalone process |
| `pkill -9 -f <stagedBinary>` | `Sources/Lib/AppexSpawner.swift` (`killStale`) | Kill a stale appex from a previous run |

(`discoverBroadcastAppexes` and `patchPackageType` are already in-process — `FileManager` + `PropertyListSerialization`.)

---

## Replacement summary

| Shell-out | In-process replacement | Confidence |
|---|---|---|
| `get_app_container` + `listapps` | `-[SimDevice installedAppsWithError:]` + `FileManager` scan of `PlugIns/*.appex` | High — selector already vendored |
| `simctl spawn` | `-[SimDevice spawnWithPath:options:terminationQueue:terminationHandler:pid:error:]` | High — options dict reverse-engineered (below) |
| `pkill` | Track the returned `pid` + termination handler; `kill(pid, SIGKILL)` | High — trivial |
| `lipo -thin` | Not needed — Security APIs operate on fat binaries directly | High |
| `segedit -extract __entitlements` | `SecStaticCodeCreateWithPath` → `SecCodeCopySigningInformation(…, kSecCSRequirementInformation)` → `kSecCodeInfoEntitlementsDict` | High — **public** API |
| `codesign --force --sign -` | `SecCodeSignerCreate` + `SecCodeSignerAddSignatureWithErrors` (adhoc identity, scrubbed entitlements) | Medium — **SPI**, symbols present at runtime |

---

## 1. Discovery → `installedAppsWithError:`

`-[SimDevice installedAppsWithError:]` returns the installed-app catalog directly from CoreSimulator (keyed by bundle ID; values carry the install `Path`, bundle identifier, app type, etc.). This replaces **both** `get_app_container` (read the `Path` for the host bundle ID) and `listapps` (iterate the whole catalog for `broadcastCapableApps`).

`discoverBroadcastAppexes(appPath:)` already scans `<app>/PlugIns/*.appex` and filters on `NSExtensionPointIdentifier == com.apple.broadcast-services-upload` with `FileManager`/`PropertyListSerialization` — keep it unchanged. Only the "how do I get `appPath`" step changes from a `simctl` call to reading `installedAppsWithError:[bundleID]["Path"]`.

---

## 2. Spawn → `spawnWithPath:options:…` (reverse-engineered recipe)

**`simctl` is just a wrapper.** `xcrun simctl` is a 729-byte bash script that `exec`s the real binary at `…/CoreSimulator.framework/Versions/A/Resources/bin/simctl`. Its `spawn` subcommand (`sub_1000229b4`) builds an `NSMutableDictionary` and calls:

```
-[SimDevice spawnWithPath:options:terminationQueue:terminationHandler:pid:error:]
```

The options dict uses these keys (all **exported** `extern NSString *const` symbols in CoreSimulator — declare them and weak-link, do **not** hardcode strings):

| Key | Value | When |
|---|---|---|
| `SimDeviceSpawnKeyArguments` | `NSArray<NSString*>` of argv, **including argv[0]** | always |
| `SimDeviceSpawnKeyEnvironment` | `NSDictionary<NSString*,NSString*>` | always |
| `SimDeviceSpawnKeyStdin` | `@0` (boxed fd) | always |
| `SimDeviceSpawnKeyStdout` | `@1` (boxed fd) | always |
| `SimDeviceSpawnKeyStderr` | `@2` (boxed fd) | always |
| `SimDeviceSpawnKeyStandalone` | `kCFBooleanFalse` (default) / `kCFBooleanTrue` | `True` only with `-s`/`--standalone` — **see §5, leave false** |
| `SimDeviceSpawnKeyWaitForDebugger` | `@1` | only with `-w` (start suspended) |
| `SimDeviceSpawnKeyBinPref` | arch string (e.g. `"arm64"`) | only with `--arch` |
| `SimDeviceSpawnKeyEnableCheckedAllocations` | `@YES` | only with `--checked-allocations` |

Observed underlying string values (cross-check only): `arguments`, `environment`, `stdin`, `stdout`, `stderr`, `standalone`, `wait_for_debugger`, `binpref`.

Critical details from the disassembly:

- **Environment is passed directly.** The `SIMCTL_CHILD_` prefix that `AppexSpawner` uses today is *purely a CLI workaround* — `simctl` strips that prefix and stores the result under `SimDeviceSpawnKeyEnvironment`. A direct call has **no such constraint**: put `DYLD_INSERT_LIBRARIES`, `GEISTCAST_SOCKET`, `GEISTCAST_HOST_SOCKET`, `DYLD_FRAMEWORK_PATH`, etc. straight into the dict. (`simctl` also re-exports a small allowlist of un-prefixed parent vars; we don't need that.)
- **`path:` must be a fully-resolved absolute path.** `simctl` does PATH/runtime-root resolution itself; CoreSimulator expects an absolute executable path. The staged appex binary path is already absolute, so this is free for us.
- **`terminationQueue:`** = `dispatch_get_global_queue(qos, 0)`; **`terminationHandler:`** is a block invoked on child exit (records exit status). `pid:` is an out `pid_t*` — **capture it for kill-stale (§3) and lifecycle.**
- **Only the synchronous variant is used** by `simctl` (`spawnWithPath:options:terminationQueue:terminationHandler:pid:error:`). An async variant exists if preferred.
- **`simctl` itself does no validation or launchd/self routing** — those decisions all happen *inside* CoreSimulator's `spawnWithPath:options:`, switched by the `Standalone` key.

Illustrative (not final code):

```objc
extern NSString *const SimDeviceSpawnKeyArguments;
extern NSString *const SimDeviceSpawnKeyEnvironment;
extern NSString *const SimDeviceSpawnKeyStandalone;
// … etc.

NSDictionary *options = @{
    SimDeviceSpawnKeyArguments:   @[ absExecutablePath ],          // argv[0] = the path
    SimDeviceSpawnKeyEnvironment: @{ @"DYLD_INSERT_LIBRARIES": extShimPath,
                                     @"GEISTCAST_SOCKET": controlSock,
                                     @"GEISTCAST_HOST_SOCKET": frameSock,
                                     /* DYLD_FRAMEWORK_PATH, DYLD_LIBRARY_PATH … */ },
    SimDeviceSpawnKeyStdin:       @0,
    SimDeviceSpawnKeyStdout:      @1,
    SimDeviceSpawnKeyStderr:      @2,
    SimDeviceSpawnKeyStandalone:  (id)kCFBooleanFalse,             // keep false — see §5
};
int pid = 0;
BOOL ok = [device spawnWithPath:absExecutablePath
                        options:options
               terminationQueue:dispatch_get_global_queue(QOS_CLASS_UTILITY, 0)
             terminationHandler:^(int status){ /* mark ended */ }
                            pid:&pid
                          error:&err];
```

---

## 3. Kill-stale → tracked pid

`pkill -9 -f <stagedBinary>` exists because the old design couldn't track the process it launched through `simctl`. With a direct spawn we get the `pid` back, so:

- Keep the spawned `pid` on the session.
- On teardown / restart, `kill(pid, SIGKILL)` (or SIGTERM then SIGKILL) in-process.
- The termination handler already tells us when it died, so stale processes are observable rather than guessed-at by command-line pattern.

No subprocess required.

---

## 4. Staging → in-process signing (Security.framework)

`recodesign` exists because patching `Info.plist` (`CFBundlePackageType → APPL`) invalidates the bundle's `_CodeSignature/CodeResources`, and `launchd_sim` refuses to spawn a bundle whose signature/entitlements don't validate. All three tools it uses are replaceable in-process:

**Read embedded entitlements** (replaces `lipo -thin` + `segedit -extract __TEXT __entitlements`) — **public SDK** (`<Security/SecCode.h>`, `<Security/SecStaticCode.h>`):

```
SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &staticCode);
SecCodeCopySigningInformation(staticCode, kSecCSRequirementInformation, &info);
CFDictionaryRef entitlements = CFDictionaryGetValue(info, kSecCodeInfoEntitlementsDict);
```

`SecCodeCopySigningInformation` handles fat binaries (it inspects the host-arch slice), so **`lipo` thinning is unnecessary**. Then scrub `application-identifier` from the dict in memory (xcodebuild bakes a team-prefixed one that `launchd_sim` rejects for adhoc).

**Adhoc re-sign with scrubbed entitlements** (replaces `codesign --force --sign - --entitlements`) — **SPI** (`SecCodeSigner.h` is *not* in the public SDK, but the symbols are present at runtime in `Security.framework`, confirmed via `dlsym`):

```
NSDictionary *params = @{
    (id)kSecCodeSignerIdentity:     (id)kCFNull,            // adhoc
    (id)kSecCodeSignerEntitlements: scrubbedEntitlementsData,
    (id)kSecCodeSignerFlags:        @(kSecCSDefaultFlags),
};
SecCodeSignerRef signer;
SecCodeSignerCreate((CFDictionaryRef)params, kSecCSDefaultFlags, &signer);
SecCodeSignerAddSignatureWithErrors(signer, staticCode, kSecCSDefaultFlags, &cfError);
```

Declare the `SecCodeSigner` SPI in a small bridging header (same pattern as the vendored CoreSimulator headers) and link `Security.framework`.

**Net in-process staging pipeline:** `FileManager` copy → `PropertyListSerialization` patch `Info.plist` → `SecCodeCopySigningInformation` read entitlements → scrub `application-identifier` → `SecCodeSigner` re-sign in place. No temp `--entitlements` file, no external tools.

---

## 5. Key finding: standalone spawn is NOT a shortcut

`simctl spawn` has `-s`/`--standalone` (option key `SimDeviceSpawnKeyStandalone`). It is tempting because a standalone spawn routes through `_spawnFromSelfWithPath:` instead of `_spawnFromLaunchdWithPath:` and would likely **bypass the launchd validation that forces staging entirely** (no plist patch, no re-sign).

**Don't.** `--standalone` means *"use a NULL mach bootstrap port"* — the spawned process **cannot reach simulator system services**. A ReplayKit broadcast extension needs those services: `BackgroundKeepalive` claims an `AVAudioSession` via `mediaserverd`, and the host app's own `RPBroadcastSampleHandler` typically does encoding/networking. A NULL-bootstrap process would be crippled.

GeistCast already spawns **non-standalone** and works. The no-shell refactor must reproduce that: **`Standalone = false`, which means `launchd_sim` validates the bundle, which means staging stays** — we just move it in-process (§4).

> If a future use case has a handler that provably needs *no* sim services, standalone could be an opt-in fast-path that skips staging. Not for the general broadcast case.

---

## Getting a `SimDevice` in-process

The broadcast side needs a `SimDevice` to call `spawnWithPath:` / `installedAppsWithError:`. This repo already resolves one in `SimulatorScreenCapture` (`SimServiceContext(forDeveloperDir:)` → `deviceSet` → `devicesByUDID[udid]`, see `SurfaceLocator`/`SimulatorScreenCapture.swift`). Reuse that path so the broadcast machinery and screen capture share a single device-resolution implementation. `CoreSimulator.framework` stays **weak-linked** (already configured for `SimulatorScreenCapture`), guarded by an `NSClassFromString("SimServiceContext")` runtime check.

---

## Open question (one unverified link)

Whether an **in-process adhoc re-sign with scrubbed entitlements** (`SecCodeSigner`) satisfies `launchd_sim` *exactly* as the `codesign` CLI does. It should — `SecCodeSigner` is the same machinery `codesign` wraps — but it is the only step not yet exercised. Two ways to close it (neither needs production code):

1. **Empirical (fast):** stage one appex in-process and `spawnWithPath:` it non-standalone; confirm it launches and the extension shim connects.
2. **Static (thorough):** disassemble CoreSimulator's `-[SimDevice spawnWithPath:options:…]` → `_spawnFromLaunchdWithPath:` to see precisely what `launchd_sim` validates (CFBundlePackageType + entitlements vs. full signature), establishing the *minimum* staging required.

---

## Reference appendix

**Binaries**
- Real `simctl`: `/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl` (`xcrun simctl` is a bash wrapper).
- CoreSimulator: `/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/CoreSimulator` (universal x86_64 + arm64e).
- Spawn handler procedure: `sub_1000229b4`.

**Selectors (already declarable from `SimDevice.h`)**
- `-[SimDevice spawnWithPath:options:terminationQueue:terminationHandler:pid:error:]`
- `-[SimDevice installedAppsWithError:]`

**Exported option-key symbols (CoreSimulator)** — confirmed via `nm -gU`:
`SimDeviceSpawnKeyArguments`, `…Environment`, `…Stdin`, `…Stdout`, `…Stderr`, `…Standalone`, `…WaitForDebugger`, `…BinPref`, `…EnableCheckedAllocations`.

**Security.framework symbols** — confirmed present at runtime via `dlsym`:
- Public (in SDK headers): `SecStaticCodeCreateWithPath`, `SecCodeCopySigningInformation`, `kSecCodeInfoEntitlementsDict`, `kSecCSRequirementInformation`.
- SPI (declare manually): `SecCodeSignerCreate`, `SecCodeSignerAddSignatureWithErrors`, `kSecCodeSignerEntitlements`, `kSecCodeSignerIdentity`.
