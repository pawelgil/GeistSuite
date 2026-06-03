import AppKit

@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String,
         keyEquivalent: String = "",
         state: NSControl.StateValue = .off,
         handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: keyEquivalent)
        self.target = self
        self.state = state
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    @objc private func invoke() {
        handler()
    }
}
