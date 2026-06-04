internal import CoreSimulatorPrivate
import Foundation
import IOSurface
import Synchronization

enum SimulatorScreenError: Error {
    case screenCallbacksUnavailable
    case noIOSurface
    case deviceNotFound(UUID)
    case frameworkUnavailable
    case serviceContextFailed(any Error)
    case deviceSetFailed(any Error)
}

/// @unchecked Sendable: `screen` and `callbackUUID` are immutable `let`s;
/// `invalidated` is protected by `Mutex`, safe from any thread (incl. `deinit`).
final class ScreenCallbackRegistrar: @unchecked Sendable {
    private let screen: any SimScreen
    private let callbackUUID: UUID
    private let invalidated = Mutex(false)

    init(
        device: SimDevice,
        queue: DispatchQueue,
        uuid: UUID,
        frameHandler: @escaping @Sendable () -> Void,
        surfaceSwapHandler: @escaping @Sendable (IOSurface) -> Void
    ) throws {
        guard let screen = SurfaceLocator.mainScreen(of: device) else {
            throw SimulatorScreenError.screenCallbacksUnavailable
        }

        self.screen = screen
        callbackUUID = uuid

        screen.registerCallbacks(
            with: callbackUUID,
            callbackQueue: queue,
            frameCallback: { frameHandler() },
            surfacesChangedCallback: { unmask, masked in
                let surface = unmask ?? masked
                guard let surface else { return }
                surfaceSwapHandler(surface)
            },
            propertiesChangedCallback: { _ in }
        )
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        let shouldUnregister = invalidated.withLock { flag in
            guard !flag else { return false }
            flag = true
            return true
        }
        guard shouldUnregister else { return }
        screen.unregisterScreenCallbacks(with: callbackUUID)
    }
}
