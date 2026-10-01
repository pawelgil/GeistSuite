import UIKit

final class PickerTestSceneDelegate: UIResponder, UIWindowSceneDelegate {
    // MARK: Properties

    var window: UIWindow?

    // MARK: Functions

    func scene(_ scene: UIScene, willConnectTo _: UISceneSession, options _: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}
