import Testing
@testable import GeistLens

@Suite("AudioRouter.decide")
struct AudioRouterDecideTests {
    private let macCam = PersistableSource.macOSCamera(deviceUID: "uid-1")
    private let mp4 = PersistableSource.video(path: "/tmp/x.mp4")
    private let image = PersistableSource.image(path: "/tmp/x.jpg")

    @Test func decide_bothSidesNil_returnsDetach() {
        let route = AudioRouter.decide(back: nil, front: nil,
                                        cameraAuthorized: true, microphoneAuthorized: true)
        #expect(route == .detach)
    }

    @Test func decide_bothSidesImage_returnsDetach() {
        let route = AudioRouter.decide(back: image, front: image,
                                        cameraAuthorized: true, microphoneAuthorized: true)
        #expect(route == .detach)
    }

    @Test func decide_backMacCamFrontNil_returnsMacMicrophone() {
        let route = AudioRouter.decide(back: macCam, front: nil,
                                        cameraAuthorized: true, microphoneAuthorized: true)
        #expect(route == .macMicrophone)
    }

    @Test func decide_frontMacCamBackNil_returnsMacMicrophone() {
        let route = AudioRouter.decide(back: nil, front: macCam,
                                        cameraAuthorized: true, microphoneAuthorized: true)
        #expect(route == .macMicrophone)
    }

    @Test func decide_bothMacCam_returnsMacMicrophone() {
        let route = AudioRouter.decide(back: macCam, front: macCam,
                                        cameraAuthorized: true, microphoneAuthorized: true)
        #expect(route == .macMicrophone)
    }

    @Test func decide_backMp4FrontMacCam_returnsMacMicrophone() {
        let route = AudioRouter.decide(back: mp4, front: macCam,
                                        cameraAuthorized: true, microphoneAuthorized: true)
        #expect(route == .macMicrophone)
    }

    @Test func decide_backMacCamFrontMp4_returnsMacMicrophone() {
        let route = AudioRouter.decide(back: macCam, front: mp4,
                                        cameraAuthorized: true, microphoneAuthorized: true)
        #expect(route == .macMicrophone)
    }

    @Test func decide_backMp4FrontNil_returnsBackAudio() {
        let route = AudioRouter.decide(back: mp4, front: nil,
                                        cameraAuthorized: true, microphoneAuthorized: true)
        #expect(route == .backAudio)
    }

    @Test func decide_backNilFrontMp4_returnsFrontAudio() {
        let route = AudioRouter.decide(back: nil, front: mp4,
                                        cameraAuthorized: true, microphoneAuthorized: true)
        #expect(route == .frontAudio)
    }

    @Test func decide_bothMp4_returnsBackAudio() {
        let route = AudioRouter.decide(back: mp4, front: mp4,
                                        cameraAuthorized: true, microphoneAuthorized: true)
        #expect(route == .backAudio)
    }

    @Test func decide_backImageFrontMp4_returnsFrontAudio() {
        let route = AudioRouter.decide(back: image, front: mp4,
                                        cameraAuthorized: true, microphoneAuthorized: true)
        #expect(route == .frontAudio)
    }

    @Test func decide_backMp4FrontImage_returnsBackAudio() {
        let route = AudioRouter.decide(back: mp4, front: image,
                                        cameraAuthorized: true, microphoneAuthorized: true)
        #expect(route == .backAudio)
    }

    @Test func decide_macCamButCameraPermissionDenied_fallsThroughToMp4() {
        let route = AudioRouter.decide(back: macCam, front: mp4,
                                        cameraAuthorized: false, microphoneAuthorized: true)
        #expect(route == .frontAudio)
    }

    @Test func decide_macCamButMicPermissionDenied_fallsThroughToMp4() {
        let route = AudioRouter.decide(back: macCam, front: mp4,
                                        cameraAuthorized: true, microphoneAuthorized: false)
        #expect(route == .frontAudio)
    }

    @Test func decide_macCamOnlyWithMicPermissionDenied_returnsDetach() {
        let route = AudioRouter.decide(back: macCam, front: image,
                                        cameraAuthorized: true, microphoneAuthorized: false)
        #expect(route == .detach)
    }
}

@Suite("AudioRouter.isMicSuppressed")
struct AudioRouterIsMicSuppressedTests {
    private let macCam = PersistableSource.macOSCamera(deviceUID: "uid-1")
    private let mp4 = PersistableSource.video(path: "/tmp/x.mp4")
    private let image = PersistableSource.image(path: "/tmp/x.jpg")

    @Test func isMicSuppressed_sideHasNoAudio_returnsFalse() {
        let suppressed = AudioRouter.isMicSuppressed(for: .back, back: image, front: mp4,
                                                       cameraAuthorized: true, microphoneAuthorized: true)
        #expect(suppressed == false)
    }

    @Test func isMicSuppressed_backIsMacCamAndMacMicWins_returnsFalse() {
        let suppressed = AudioRouter.isMicSuppressed(for: .back, back: macCam, front: nil,
                                                       cameraAuthorized: true, microphoneAuthorized: true)
        #expect(suppressed == false)
    }

    @Test func isMicSuppressed_backIsMp4AndMacCamOnFrontWins_returnsTrue() {
        let suppressed = AudioRouter.isMicSuppressed(for: .back, back: mp4, front: macCam,
                                                       cameraAuthorized: true, microphoneAuthorized: true)
        #expect(suppressed == true)
    }

    @Test func isMicSuppressed_frontIsMp4AndMacCamOnBackWins_returnsTrue() {
        let suppressed = AudioRouter.isMicSuppressed(for: .front, back: macCam, front: mp4,
                                                       cameraAuthorized: true, microphoneAuthorized: true)
        #expect(suppressed == true)
    }

    @Test func isMicSuppressed_frontIsMp4WhenBackAudioWins_returnsTrue() {
        let suppressed = AudioRouter.isMicSuppressed(for: .front, back: mp4, front: mp4,
                                                       cameraAuthorized: true, microphoneAuthorized: true)
        #expect(suppressed == true)
    }

    @Test func isMicSuppressed_backIsMp4WhenBackAudioWins_returnsFalse() {
        let suppressed = AudioRouter.isMicSuppressed(for: .back, back: mp4, front: mp4,
                                                       cameraAuthorized: true, microphoneAuthorized: true)
        #expect(suppressed == false)
    }

    @Test func isMicSuppressed_frontIsMp4WhenOnlyFrontHasAudio_returnsFalse() {
        let suppressed = AudioRouter.isMicSuppressed(for: .front, back: nil, front: mp4,
                                                       cameraAuthorized: true, microphoneAuthorized: true)
        #expect(suppressed == false)
    }
}
