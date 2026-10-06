import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
	var window: UIWindow?

	func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
		let window: UIWindow = UIWindow(frame: UIScreen.main.bounds)
		window.rootViewController = GalleryViewController()
		self.window = window
		window.makeKeyAndVisible()
		if ProcessInfo.processInfo.arguments.contains("--export-comparisons") {
			DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: {
				do { try ComparisonExporter.export() }
				catch { print("COMPARISON_EXPORT_FAILED: \(error)") }
			})
		}
		return true
	}
}
