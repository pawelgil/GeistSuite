# AGENTS.md

Project-level rules for AI agents working in this repo. These apply to all sessions.

## Where things live

The repo is a monorepo with three product families at the top level:

- `GeistCore/` — shared internal targets: `GeistKit` (Swift utilities, the `GeistLog` per-module logger, event-driven simulator detection via CoreSimulator notifications), `CoreSimulatorPrivate` (C SPI headers), `SharedShimCore` (neutral C used inside iOS shim dylibs). Also houses the `BuildShim` SPM plugin and `GeistKitTests`.
- `GeistLens/` — camera product family: `GeistCamera` (public Swift library), `GeistCameraShimCore` (testable C), `GeistCamShim` (iOS dylib ObjC sources), `Tests/GeistCameraTests/`, and `App/` (the GeistLens.app).
- `GeistCast/` — broadcast product family: `GeistBroadcast` (public Swift library), `GeistBroadcastShimCore` (testable C + ShimLog/ControlSocket runtime), `GeistBroadcastAppShim` + `GeistBroadcastExtensionShim` (iOS dylib ObjC sources), `SimulatorScreenCapture` (macOS HAL bridge — broadcast-only), `Tests/GeistBroadcastTests/`, and `App/` (the GeistCast.app).

Folder names and module names are intentionally different: folders are `GeistCore`/`GeistLens`/`GeistCast`; SPM module names are `GeistKit`/`GeistCamera`/`GeistBroadcast`. Don't conflate them.

`Package.swift` declares every target with an explicit `path:`. When adding a new target, place its sources under the right product family and add the `path:` declaration. Test targets follow the same pattern.

## Building and verifying

- Library + iOS shim dylibs: `swift build` from repo root. The `BuildShim` plugin (in `GeistCore/Plugins/BuildShim/`) compiles the iOS Simulator dylibs and lands them in each library's resource bundle (`Geist_GeistCamera.bundle`, `Geist_GeistBroadcast.bundle`). The plugin branches on target name; cross-product shim sources never compile into the wrong target.
- Apps: `cd <product>/App/ && xcodegen generate && xcodebuild -project <App>.xcodeproj -scheme <App> -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build`.
- `xcodegen` is the source of truth for the Xcode project files. Never edit `*.xcodeproj/project.pbxproj` directly. Regenerate via `xcodegen generate` after touching anything under `<product>/App/Sources/`.
- `swift test` must finish under 1 minute. Anything longer is a hanging test, not a slow one — find it.

## Logging

Each module (library or app) owns its own logger identity. Pattern:

```swift
// <Module>/Logging.swift  — module-internal
import GeistKit
internal let log = GeistLog(subsystem: "com.geist.<module>")
```

Call sites just write `log.notice(...)`, `log.warn(...)`, etc. Don't add a static `Log` facade. Don't shadow the module-internal `log` with a same-named symbol elsewhere in the module — same-module symbols win over re-exports, which silently breaks the dual-write.

`GeistLog` dual-writes: `os.Logger` for subsystem-filterable Console.app entries, and `FileLogSink` for an on-disk mirror at `~/Library/Logs/<bundle-name>/daemon.log` (subdirectory derives from `Bundle.main.CFBundleName`).

Shim-side logging (ObjC running inside iOS Simulator processes) is contract-driven:
- Camera shim reads `GEISTCAM_LOG` (a full file path); the GeistLens app sets it via `launchctl setenv` to `~/Library/Logs/GeistLens/shim.log`.
- Broadcast shims read `GEISTCAST_LOG_DIR` (a directory); the GeistCast app sets it to `~/Library/Logs/GeistCast/` and the shims write `shim-host.log` / `shim-extension.log` inside.

Don't rename either env-var contract without updating both sides at once.

`Report Issue` in each app collects the daemon log + the shim log(s) from the same directory. Anything you write via `log.notice/warn/error/...` shows up there.

## Hard stop on divergences

If you find yourself needing to diverge from the agreed plan or do a workaround — **stop and ask, don't continue no matter what.**

This rule applies broadly, not just to major architectural calls. Specifically, stop when:

- A research-validated pattern doesn't compile cleanly (try one alternative, then stop)
- A behavior changes as a side effect of an approach (queues being shared, fire-and-forget semantics, async vs sync API shape)
- A public API shape diverges from what was discussed
- Anything produces a result materially different from what was agreed

Task-list completion pressure is not a reason to continue. Bias toward stopping. When in doubt, write a brief summary of the deviation and the alternative(s), and ask.

## Unit tests

Write all tests and test suites exactly following the patterns in Meszaros's *XUnit Test Patterns: Refactoring Test Code*. Specifically:

- **Framework:** Swift Testing only (`@Test`, `@Suite`, `#expect`, `#require`). No XCTest.
- **Black-box only.** Do not raise visibility (`private` → `internal`, `internal` → `public`) for the sake of a test. If the public surface is not testable, introduce a protocol seam and inject a test double instead. `@testable import` is the designated Swift testing boundary and is fine — it doesn't count as raising visibility.
- **Test Double roles are strict.** Dummy passes arguments; Stub returns canned values; Spy records interactions; Mock verifies expectations; Fake provides a simpler working implementation. If you find yourself needing a Spy that stubs, a Stub that records, or any other hybrid, **stop** — that points at a production-code architecture smell (the SUT is doing too much, or a collaborator has mixed responsibilities), not a test concession. Fix the production code.
- **Other test smells** likewise indicate production issues to fix, not tolerate.
- **Test naming:** `Subject_Scenario_Expected` for method names. Optional `@Test("…")` display name where a sentence aids clarity.
- **Doubles live next to their tests** as private types in the same file. Duplicate first; deduplicate only when it hurts.

## Comments

Default to writing **no comments**. Only add one when the WHY is non-obvious:

- A workaround for a specific bug
- A hidden constraint or subtle invariant
- A `@unchecked Sendable` / `nonisolated(unsafe)` safety invariant
- Behavior that would surprise a reader

Do not explain WHAT the code does — well-named identifiers already do that. Do not reference the current task, fix, or callers ("used by X", "added for the Y flow", "TODO from issue #123") — those belong in the PR description and rot as the codebase evolves.

If removing a comment wouldn't confuse a future reader, don't write it.
