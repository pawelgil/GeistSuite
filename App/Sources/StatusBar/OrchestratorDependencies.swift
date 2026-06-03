import AppKit
import Foundation
import Geist

protocol PermissionsQuerying: Sendable {
    var cameraAuthorized: Bool { get }
    var microphoneAuthorized: Bool { get }
}

protocol MediaSourceConstructing: Sendable {
    func make(_ persistable: PersistableSource?, wantsAudio: Bool) async -> any MediaSource
}

protocol SessionMaking: Sendable {
    func make(simulatorUDID: String, bundleID: String,
              delegate: (any GeistCameraSessionDelegate)?) -> any SessionDriving
}

@MainActor
protocol AlertPresenting: AnyObject {
    func showRecordingInProgress()
}

// MARK: - Production implementations

struct DefaultPermissions: PermissionsQuerying {
    var cameraAuthorized: Bool { Permissions.cameraAuthorized }
    var microphoneAuthorized: Bool { Permissions.microphoneAuthorized }
}

struct DefaultMediaSourceFactory: MediaSourceConstructing {
    func make(_ persistable: PersistableSource?, wantsAudio: Bool) async -> any MediaSource {
        await MediaSourceFactory.make(persistable, wantsAudio: wantsAudio)
    }
}

struct DefaultSessionMaker: SessionMaking {
    func make(simulatorUDID: String, bundleID: String,
              delegate: (any GeistCameraSessionDelegate)?) -> any SessionDriving {
        GeistCameraSession(simulator: simulatorUDID, bundleID: bundleID, delegate: delegate)
    }
}

@MainActor
final class DefaultAlertPresenter: AlertPresenting {
    func showRecordingInProgress() {
        let alert = NSAlert()
        alert.messageText = "Recording in Progress"
        alert.informativeText = "Stop the recording in the simulator app before switching the camera source."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
