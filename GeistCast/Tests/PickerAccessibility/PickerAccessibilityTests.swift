import Testing
import UIKit

@MainActor
struct PickerAccessibilityTests {
    // MARK: Nested Types

    private final class ActionSpy: NSObject {
        // MARK: Properties

        var count = 0

        // MARK: Functions

        @objc func activate() {
            count += 1
        }
    }

    // MARK: Functions

    @Test func footer_titleChange_exposesSingleButtonWithCurrentLabel() {
        let button = GCFooterButton(frame: .zero)
        button.setTitle("Start Recording")
        #expect(button.isAccessibilityElement)
        #expect(button.accessibilityTraits.contains(.button))
        #expect(button.accessibilityLabel == "Start Recording")
        #expect(button.subviews.allSatisfy { !$0.isAccessibilityElement })
        button.setTitle("Stop Recording")
        #expect(button.accessibilityLabel == "Stop Recording")
    }

    @Test func microphone_toggle_exposesCurrentValue() throws {
        let button = try #require(GCCircleGlassButton(size: 56))
        button.isOn = false
        #expect(button.isAccessibilityElement)
        #expect(button.accessibilityTraits.contains(.button))
        #expect(button.accessibilityValue == "Off")
        button.isOn = true
        #expect(button.accessibilityValue == "On")
    }

    @Test func footer_accessibilityActivation_obeysEnabledState() {
        let button = GCFooterButton(frame: .zero)
        let spy = ActionSpy()
        button.addTarget(spy, action: #selector(ActionSpy.activate), for: .touchUpInside)
        #expect(button.accessibilityActivate())
        #expect(spy.count == 1)
        button.isEnabled = false
        #expect(!button.accessibilityActivate())
        #expect(spy.count == 1)
        #expect(button.accessibilityTraits.contains(.notEnabled))
    }

    @Test func backdrop_activation_invokesDismissalWithoutAddingContent() {
        let backdrop = GCDismissBackdropView(frame: .zero)
        let spy = ActionSpy()
        backdrop.dismissalHandler = { spy.activate() }
        #expect(backdrop.accessibilityActivate())
        #expect(spy.count == 1)
        #expect(backdrop.subviews.isEmpty)
        #expect(backdrop.accessibilityLabel == "Dismiss broadcast sheet")
    }

    @Test func backdrop_starting_rejectsActivationAndEscape() {
        let backdrop = GCDismissBackdropView(frame: .zero)
        let spy = ActionSpy()
        backdrop.dismissalHandler = { spy.activate() }
        backdrop.dismissalEnabled = false
        #expect(!backdrop.accessibilityActivate())
        #expect(!backdrop.accessibilityPerformEscape())
        #expect(spy.count == 0)
        #expect(backdrop.accessibilityTraits.contains(.notEnabled))
    }

    @Test func backdrop_escape_invokesOwnedDismissal() {
        let backdrop = GCDismissBackdropView(frame: .zero)
        let spy = ActionSpy()
        backdrop.dismissalHandler = { spy.activate() }
        #expect(backdrop.accessibilityPerformEscape())
        #expect(spy.count == 1)
    }

    @Test func backdrop_missingHandler_reportsUnsupportedActivation() {
        let backdrop = GCDismissBackdropView(frame: .zero)
        #expect(!backdrop.accessibilityActivate())
    }

    @Test func microphone_accessibilityActivation_obeysEnabledState() throws {
        let button = try #require(GCCircleGlassButton(size: 56))
        let spy = ActionSpy()
        button.addTarget(spy, action: #selector(ActionSpy.activate), for: .touchUpInside)

        #expect(button.accessibilityActivate())
        #expect(spy.count == 1)
        button.isEnabled = false
        #expect(!button.accessibilityActivate())
        #expect(spy.count == 1)
        #expect(button.accessibilityTraits.contains(.notEnabled))
    }
}
