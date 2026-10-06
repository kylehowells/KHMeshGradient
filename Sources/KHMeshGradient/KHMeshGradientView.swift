import Metal
import UIKit

/// A demand-rendered, Metal-backed mesh gradient. All configuration uses normalized
/// coordinates, with (0, 0) at the top-left and (1, 1) at the bottom-right.
/// Points, Bézier handles, and colors animate inside `UIView.animate` blocks.
open class KHMeshGradientView: UIView {

	public struct MeshSize: Equatable, Sendable {
		public var width: Int
		public var height: Int
		public init(width: Int, height: Int) { self.width = width; self.height = height }
		public var vertexCount: Int {
			let result = self.width.multipliedReportingOverflow(by: self.height)
			return result.overflow ? 0 : result.partialValue
		}
	}

	/// Each handle is an absolute location in the same coordinate space as `position`.
	public struct BezierPoint: Equatable, Sendable {
		public var position: CGPoint
		public var leadingControlPoint: CGPoint
		public var topControlPoint: CGPoint
		public var trailingControlPoint: CGPoint
		public var bottomControlPoint: CGPoint
		public init(position: CGPoint, leadingControlPoint: CGPoint, topControlPoint: CGPoint,
			trailingControlPoint: CGPoint, bottomControlPoint: CGPoint) {
			self.position = position
			self.leadingControlPoint = leadingControlPoint
			self.topControlPoint = topControlPoint
			self.trailingControlPoint = trailingControlPoint
			self.bottomControlPoint = bottomControlPoint
		}
	}

	public enum ColorSpace: Int, Sendable {
		/// Interpolate encoded sRGB components. Corresponds to SwiftUI's device mode.
		case device = 0
		/// Interpolate in Oklab. Apple's perceptual implementation is not public.
		case perceptual = 1
		/// Additional option: interpolate linear-light sRGB components.
		case linear = 2
	}

	public enum DebugMode: Int, Sendable {
		case none
		/// Draw patch boundaries and colored vertex markers over the gradient.
		case mesh
		/// Also show the active Bézier handles and their connecting lines.
		case controlPoints
		/// Show a sampled parameter grid within every patch.
		case tessellation
	}

	public override class var layerClass: AnyClass { KHMeshGradientLayer.self }
	private var meshLayer: KHMeshGradientLayer { self.layer as! KHMeshGradientLayer }

	/// Grid dimensions, independent of the view's size. A mesh needs at least 2 × 2 vertices.
	open var meshSize: MeshSize = MeshSize(width: 2, height: 2) {
		didSet {
			if self.meshSize != oldValue { self.meshLayer.removeMeshAnimations() }
			self.updateMesh()
		}
	}
	/// Positions in row-major order. Setting this switches to automatic Bézier handles.
	open var points: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)] {
		didSet { self.bezierPoints = nil; self.updateMesh() }
	}
	/// Explicit positions and handles. Setting a non-nil value selects explicit geometry.
	/// Setting nil selects `points` again. Setting `points` also selects automatic geometry.
	open var bezierPoints: [BezierPoint]? {
		didSet { self.updateMesh() }
	}
	/// Dynamic UIKit colors, resolved against this view's traits before rendering.
	/// Setting these switches away from `resolvedColors`.
	open var colors: [UIColor] = [.clear, .clear, .clear, .clear] {
		didSet { self.resolvedColors = nil; self.updateMesh() }
	}
	/// Already-resolved colors. Non-nil selects this source; nil selects `colors` again.
	open var resolvedColors: [CGColor]? {
		didSet { self.updateMesh() }
	}
	/// Fills only pixels outside the mesh. Semi-transparent mesh pixels instead reveal
	/// the view's inherited `backgroundColor` or whatever is behind the view.
	open var meshBackgroundColor: UIColor = .clear { didSet { self.updateMesh() } }
	/// Use cubic color interpolation derived from neighboring vertices.
	open var smoothsColors: Bool = true { didSet { self.updateMesh() } }
	open var colorSpace: ColorSpace = .device { didSet { self.updateMesh() } }
	open var debugMode: DebugMode = .none { didSet { self.updateMesh() } }
	/// Tessellation segments per patch axis, clamped to 2...128. Default: 48.
	open var subdivisions: Int = 48 { didSet { self.updateMesh() } }
	/// Explicitly suspend GPU rendering. Changes are displayed when resumed.
	open var isRenderingSuspended: Bool = false { didSet { self.updateRenderingAvailability() } }

	/// Nil when configuration is renderable. Partial sequential updates clear the
	/// mesh until dimensions, positions, and colors agree; they never trap.
	public private(set) var configurationError: String?
	/// The last synchronous Metal error, or nil after successful rendering.
	public var renderingError: Error? { self.meshLayer.renderingError }
	/// Successful onscreen submissions. Useful for checking that idle rendering stops.
	public var renderedFrameCount: UInt64 { self.meshLayer.renderedFrameCount }
	/// Enable aggregate CPU/GPU diagnostics. Off by default to avoid timing and
	/// callback overhead in normal use. CPU timings exclude public property setters.
	public var collectsRenderingStatistics: Bool {
		get { self.meshLayer.collectsRenderingStatistics }
		set { self.meshLayer.collectsRenderingStatistics = newValue }
	}
	public var renderingStatistics: RenderingStatistics { self.meshLayer.renderingStatistics }
	/// In-flight GPU callbacks retain their previous statistics store, so a reset
	/// cannot attribute an earlier phase's completions to the new phase.
	public func resetRenderingStatistics() { self.meshLayer.resetRenderingStatistics() }
	/// The effective model geometry, including automatically generated handles.
	/// Copy this array into `bezierPoints` to start editing handles explicitly.
	public var resolvedBezierPoints: [BezierPoint] { self.meshLayer.snapshot()?.vertices ?? [] }
	/// Positions from the presentation layer, for inspection during animation.
	public var presentationPoints: [CGPoint] {
		let layer: KHMeshGradientLayer = self.meshLayer.presentation() ?? self.meshLayer
		return layer.snapshot()?.vertices.map({ $0.position }) ?? []
	}

	private var applicationIsActive: Bool = true
	private var resolvedTraits: UITraitCollection?

	public override init(frame: CGRect) {
		super.init(frame: frame)
		self.commonInit()
	}

	@available(*, unavailable, message: "Use init(frame:) for this programmatic view.")
	public required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

	private func commonInit() {
		self.isOpaque = false
		self.meshLayer.isOpaque = false
		if #available(iOS 17.0, *) {
			self.registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self,
				UITraitDisplayGamut.self, UITraitUserInterfaceLevel.self], target: self, action: #selector(self.colorTraitsDidChange))
		}
		self.applicationIsActive = UIApplication.shared.applicationState != .background
		NotificationCenter.default.addObserver(self, selector: #selector(self.applicationWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(self.applicationDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
		self.updateMesh()
		self.updateRenderingAvailability()
	}

	deinit { NotificationCenter.default.removeObserver(self) }

	/// Resolve UIKit's current animation action, then retarget a copy to the mesh key.
	/// The layer owns interpolation; a Swift stored property alone cannot animate.
	open override func action(for layer: CALayer, forKey event: String) -> CAAction? {
		guard KHMeshGradientLayer.isMeshKey(event) else { return super.action(for: layer, forKey: event) }
		let templateAction = super.action(for: layer, forKey: "backgroundColor")
		guard !CATransaction.disableActions(), UIView.areAnimationsEnabled else {
			layer.removeAnimation(forKey: event)
			return NSNull()
		}
		guard let template: CABasicAnimation = templateAction as? CABasicAnimation else {
			// UIViewPropertyAnimator's opaque action retains backgroundColor's key path.
			// Forwarding it would animate the wrong property. Ordinary animations and
			// springs provide copyable CABasicAnimation / CASpringAnimation actions.
			layer.removeAnimation(forKey: event)
			return NSNull()
		}
		guard let previous: Any = (layer.presentation() ?? layer).value(forKey: event) else { return NSNull() }
		let animation: CABasicAnimation = template.copy() as! CABasicAnimation
		animation.keyPath = event
		animation.fromValue = previous
		animation.toValue = nil
		animation.byValue = nil
		animation.isAdditive = false
		animation.isCumulative = false
		return animation
	}

	/// Render the current model or presentation mesh to a real Metal texture and read
	/// it back. Intended for exports/tests, not the onscreen frame loop. Blocks for GPU completion.
	/// The returned image includes `meshBackgroundColor`, but not UIView background or subviews.
	public func renderedImage(size: CGSize, scale: CGFloat = 1, usesPresentationValues: Bool = false) throws -> UIImage {
		self.refreshColorAppearanceIfNeeded()
		let layer: KHMeshGradientLayer = usesPresentationValues ? (self.meshLayer.presentation() ?? self.meshLayer) : self.meshLayer
		guard let mesh: MeshGeometry.Snapshot = layer.snapshot() else {
			throw NSError(domain: "KHMeshGradient", code: 1, userInfo: [NSLocalizedDescriptionKey: self.configurationError ?? "Invalid mesh configuration."])
		}
		return try MeshRenderer.shared.get().image(mesh, size: size, scale: scale)
	}

	private func updateMesh() {
		self.resolvedTraits = self.traitCollection
		let size: MeshSize = self.meshSize
		let vertices: [BezierPoint] = self.bezierPoints ?? MeshGeometry.automaticVertices(points: self.points, size: size)
		let colors: [CGColor] = self.resolvedColors ?? self.colors.map({ $0.resolvedColor(with: self.traitCollection).cgColor })
		var error: String?
		if size.width < 2 || size.height < 2 || size.vertexCount <= 0 || size.vertexCount > 4096 {
			error = "Mesh dimensions must be at least 2 × 2, with at most 4096 vertices."
		}
		else if vertices.count != size.vertexCount || colors.count != size.vertexCount {
			error = "Positions and colors must each contain meshSize.width × meshSize.height elements."
		}
		else if vertices.contains(where: { v in
			[v.position, v.leadingControlPoint, v.topControlPoint, v.trailingControlPoint, v.bottomControlPoint].contains(where: { !$0.x.isFinite || !$0.y.isFinite })
		}) {
			error = "All mesh positions and handles must be finite."
		}
		self.configurationError = error
		self.meshLayer.meshSize = size
		self.meshLayer.isValid = error == nil
		self.meshLayer.smoothsColors = self.smoothsColors
		self.meshLayer.colorSpace = self.colorSpace
		self.meshLayer.debugMode = self.debugMode
		self.meshLayer.subdivisions = min(128, max(2, self.subdivisions))
		if error == nil {
			for (index, vertex) in vertices.enumerated() {
				self.meshLayer.setMeshValue(NSValue(cgPoint: vertex.position), forKey: "mesh_point_\(index)")
				self.meshLayer.setMeshValue(NSValue(cgPoint: vertex.leadingControlPoint), forKey: "mesh_leading_\(index)")
				self.meshLayer.setMeshValue(NSValue(cgPoint: vertex.topControlPoint), forKey: "mesh_top_\(index)")
				self.meshLayer.setMeshValue(NSValue(cgPoint: vertex.trailingControlPoint), forKey: "mesh_trailing_\(index)")
				self.meshLayer.setMeshValue(NSValue(cgPoint: vertex.bottomControlPoint), forKey: "mesh_bottom_\(index)")
				self.meshLayer.setMeshValue(colors[index], forKey: "mesh_color_\(index)")
			}
		}
		self.meshLayer.setMeshValue(self.meshBackgroundColor.resolvedColor(with: self.traitCollection).cgColor, forKey: "mesh_background")
		self.meshLayer.setNeedsDisplay()
	}

	open override func layoutSubviews() {
		super.layoutSubviews()
		self.refreshColorAppearanceIfNeeded()
		let scale: CGFloat = self.window?.screen.scale ?? self.traitCollection.displayScale
		let actualScale: CGFloat = scale > 0 ? scale : 1
		let size: CGSize = CGSize(width: (self.bounds.width * actualScale).rounded(.up), height: (self.bounds.height * actualScale).rounded(.up))
		if self.meshLayer.drawableSize != size || self.meshLayer.contentsScale != actualScale {
			CATransaction.begin()
			CATransaction.setDisableActions(true)
			self.meshLayer.contentsScale = actualScale
			self.meshLayer.drawableSize = size
			CATransaction.commit()
			self.meshLayer.setNeedsDisplay()
		}
	}

	open override func didMoveToWindow() {
		super.didMoveToWindow()
		self.refreshColorAppearanceIfNeeded()
		self.updateRenderingAvailability()
		self.setNeedsLayout()
	}

	open override var isHidden: Bool { didSet { self.updateRenderingAvailability() } }

	open override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
		super.traitCollectionDidChange(previousTraitCollection)
		if self.traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
			UIView.performWithoutAnimation({ self.updateMesh() })
		}
	}

	private func updateRenderingAvailability() {
		self.meshLayer.isRenderingEnabled = self.window != nil && !self.isHidden && !self.isRenderingSuspended && self.applicationIsActive
		if self.meshLayer.isRenderingEnabled { self.meshLayer.setNeedsDisplay() }
	}
	private func refreshColorAppearanceIfNeeded() {
		if self.traitCollection.hasDifferentColorAppearance(comparedTo: self.resolvedTraits) {
			UIView.performWithoutAnimation({ self.updateMesh() })
		}
	}
	@objc private func colorTraitsDidChange() { self.refreshColorAppearanceIfNeeded() }
	@objc private func applicationWillResignActive() { self.applicationIsActive = false; self.updateRenderingAvailability() }
	@objc private func applicationDidBecomeActive() { self.applicationIsActive = true; self.updateRenderingAvailability() }
}

#if DEBUG
import SwiftUI

private struct MeshPreview: UIViewRepresentable {
	func makeUIView(context: Context) -> KHMeshGradientView {
		let view: KHMeshGradientView = KHMeshGradientView()
		view.colors = [.systemPurple, .systemMint, .systemOrange, .systemBlue]
		view.debugMode = .controlPoints
		return view
	}
	func updateUIView(_ uiView: KHMeshGradientView, context: Context) { uiView.setNeedsLayout(); uiView.layoutIfNeeded() }
}

private struct KHMeshGradientPreview: PreviewProvider {
	static var previews: some View { MeshPreview().frame(width: 320, height: 240).previewDisplayName("Metal mesh + handles") }
}
#endif
