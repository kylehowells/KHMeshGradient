import QuartzCore

/// Let UIKit's action register the original animation with its property animator.
/// Copying the animation before retargeting leaves UIKit tracking the old key.
final class MeshAnimationAction: NSObject, CAAction {
	let template: CAAction
	let redrawTemplate: CAAction
	let fromValue: Any
	init(template: CAAction, redrawTemplate: CAAction, fromValue: Any) {
		self.template = template
		self.redrawTemplate = redrawTemplate
		self.fromValue = fromValue
	}
	func run(forKey event: String, object: Any, arguments: [AnyHashable: Any]?) {
		guard let layer: KHMeshGradientLayer = object as? KHMeshGradientLayer else { return }
		layer.runUIKitAction(self.template, forKey: event, fromValue: self.fromValue, arguments: arguments)
		// Give every mesh key an independently registered redraw driver, so its
		// pause/scrub/resume lifetime follows the animator rather than wall time.
		layer.runUIKitAction(self.redrawTemplate, forKey: "redrawProgress", storageKey: "redraw_\(event)", fromValue: 0, toValue: 1, arguments: arguments)
	}
}
