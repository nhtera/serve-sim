import UIKit

/// The runner's host app: a black screen. The XCUITest bundle it carries is
/// the runner; this app only has to exist (XCUITest needs a target app) and
/// stay out of the way.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let root = UIViewController()
        root.view.backgroundColor = .black
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
