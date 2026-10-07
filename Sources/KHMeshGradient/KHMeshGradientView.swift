import Metal
import UIKit

/// A demand-rendered, Metal-backed mesh gradient. All configuration uses normalized
/// coordinates, with (0, 0) at the top-left and (1, 1) at the bottom-right.
/// Points, Bézier handles, and colors animate with `UIView.animate` and
/// `UIViewPropertyAnimator`, including interactive scrubbing.
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
		/// Show the actual selected triangle grid within every patch.
		case tessellation
	}

	public override class var layerClass: AnyClass { KHMeshGradientLayer.self }
	private var meshLayer: KHMeshGradientLayer { self.layer as! KHMeshGradientLayer }

	/// Grid dimensions, independent of the view's size. A mesh needs at least 2 × 2 vertices.
	open var meshSize: MeshSize = MeshSize(width: 2, height: 2) {
		didSet {
			if self.meshSize != oldValue {
				self.meshLayer.removeMeshAnimations()
				self.colorSources.removeAll()
				self.animationColorSources.removeAll()
			}
			self.updateMesh()
		}
	}
	private var storedPoints: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)]
	/// Positions in row-major order. Setting this switches to automatic Bézier handles.
	open var points: [CGPoint] {
		get { self.storedPoints }
		set { self.storedPoints = newValue; self.storedBezierPoints = nil; self.updateMesh(resolvesColors: false) }
	}
	private var storedBezierPoints: [BezierPoint]?
	/// Explicit positions and handles. Setting a non-nil value selects explicit geometry.
	/// Setting nil selects `points` again. Setting `points` also selects automatic geometry.
	open var bezierPoints: [BezierPoint]? {
		get { self.storedBezierPoints }
		set { self.storedBezierPoints = newValue; self.updateMesh(resolvesColors: false) }
	}
	private var storedColors: [UIColor] = [.clear, .clear, .clear, .clear]
	/// Dynamic UIKit colors, resolved against this view's traits before rendering.
	/// Setting these switches away from `resolvedColors`.
	open var colors: [UIColor] {
		get { self.storedColors }
		set { self.storedColors = newValue; self.storedResolvedColors = nil; self.updateMesh() }
	}
	private var storedResolvedColors: [CGColor]?
	/// Already-resolved colors. Non-nil selects this source; nil selects `colors` again.
	open var resolvedColors: [CGColor]? {
		get { self.storedResolvedColors }
		set { self.storedResolvedColors = newValue; self.updateMesh() }
	}
	private var storedMeshBackgroundColor: UIColor = .clear
	/// Fills only pixels outside the mesh. Semi-transparent mesh pixels instead reveal
	/// the view's inherited `backgroundColor` or whatever is behind the view.
	open var meshBackgroundColor: UIColor {
		get { self.storedMeshBackgroundColor }
		set { self.storedMeshBackgroundColor = newValue; self.updateMesh() }
	}
	/// Use cubic color interpolation derived from neighboring vertices.
	open var smoothsColors: Bool = true { didSet { self.updateMesh(resolvesColors: false) } }
	open var colorSpace: ColorSpace = .device { didSet { self.updateMesh(resolvesColors: false) } }
	open var debugMode: DebugMode = .none { didSet { self.updateMesh(resolvesColors: false) } }
	/// Geometry segments per patch axis. Zero (the default) selects density from
	/// curvature and framebuffer size. Positive values select a fixed density,
	/// clamped to 1...128. Color is evaluated per pixel at every density.
	open var subdivisions: Int = 0 { didSet { self.updateMesh(resolvesColors: false) } }
	/// Target geometric deviation in framebuffer pixels for adaptive tessellation.
	/// Default: 0.5; clamped to 0.05...8. Density is capped at 128 segments and
	/// 65,536 cells per mesh, so extreme inputs can exceed this target. Fixed
	/// `subdivisions` bypass this setting. This is not a color or pixel-parity bound.
	open var maximumGeometryError: CGFloat = 0.5 { didSet { self.updateMesh(resolvesColors: false) } }
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
		return self.meshLayer.displayedSnapshot()?.vertices.map({ $0.position }) ?? []
	}

	private var applicationIsActive: Bool = true
	private var resolvedTraits: UITraitCollection?
	private var colorSources: [String: UIColor] = [:]
	private var configurationAnimationTemplate: CAAction?
	private var cachedColors: [CGColor] = []
	private var cachedRGBAColors: [SIMD4<Float>] = []
	private var cachedBackground: CGColor = UIColor.clear.cgColor
	private var cachedRGBABackground: SIMD4<Float> = .zero
	private var animationColorSources: [String: [(CGColor, UIColor)]] = [:]

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
		self.meshLayer.modelValueDidChange = { [weak self] key, value in self?.restoreModelValue(value, forKey: key) }
		self.updateMesh()
		self.updateRenderingAvailability()
	}

	deinit { NotificationCenter.default.removeObserver(self) }

	/// Resolve UIKit's current animation action and route it to the mesh key.
	/// The layer owns interpolation; a Swift stored property alone cannot animate.
	open override func action(for layer: CALayer, forKey event: String) -> CAAction? {
		guard KHMeshGradientLayer.isMeshKey(event) else { return super.action(for: layer, forKey: event) }
		if self.meshLayer.isSeedingMeshValues { return NSNull() }
		guard !CATransaction.disableActions(), UIView.areAnimationsEnabled else {
			if self.meshLayer.isSettingMeshValue { self.animationColorSources[event] = nil }
			layer.removeAnimation(forKey: event)
			return NSNull()
		}
		let templateAction: CAAction? = self.configurationAnimationTemplate ?? super.action(for: layer, forKey: "backgroundColor")
		if !(templateAction is CABasicAnimation) { self.configurationAnimationTemplate = nil }
		guard let previous: Any = layer.presentation()?.value(forKey: event) ?? layer.value(forKey: event) else { return NSNull() }
		guard let template: CABasicAnimation = templateAction as? CABasicAnimation else {
			if let action: CAAction = templateAction, !(action is NSNull) {
				if let source = self.colorSources[event], let color = previous as! CGColor?,
					source.resolvedColor(with: self.traitCollection).cgColor == color {
					if layer.animation(forKey: event) == nil { self.animationColorSources[event] = nil }
					self.animationColorSources[event, default: []].append((color, source))
				}
				let redrawAction: CAAction = super.action(for: layer, forKey: "backgroundColor") ?? NSNull()
				return MeshAnimationAction(template: action, redrawTemplate: redrawAction, fromValue: previous)
			}
			if self.meshLayer.isSettingMeshValue { self.animationColorSources[event] = nil }
			layer.removeAnimation(forKey: event)
			return NSNull()
		}
		self.animationColorSources[event] = nil
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
		let snapshot = usesPresentationValues ? self.meshLayer.displayedSnapshot() : self.meshLayer.snapshot()
		guard let mesh: MeshGeometry.Snapshot = snapshot else {
			throw NSError(domain: "KHMeshGradient", code: 1, userInfo: [NSLocalizedDescriptionKey: self.configurationError ?? "Invalid mesh configuration."])
		}
		return try MeshRenderer.shared.get().image(mesh, size: size, scale: scale)
	}

	/// UIKit writes the layer's model back when an interactive animator finishes at
	/// its start/current position. Keep the UIKit-facing configuration in sync without
	/// creating new actions or overwriting other animations in the same transaction.
	private func restoreModelValue(_ value: Any?, forKey key: String) {
		if key == "mesh_background", let color = value as! CGColor? {
			self.storedMeshBackgroundColor = self.restoredColor(color, forKey: key)
			self.cachedBackground = color
			self.cachedRGBABackground = MeshGeometry.rgba(color)
			self.colorSources[key] = self.storedMeshBackgroundColor
			return
		}
		let parts = key.split(separator: "_")
		guard parts.count == 3, let index = Int(parts[2]), index >= 0 else { return }
		if parts[1] == "color", let color = value as! CGColor? {
			if index < self.cachedColors.count { self.cachedColors[index] = color; self.cachedRGBAColors[index] = MeshGeometry.rgba(color) }
			if self.storedResolvedColors != nil, index < self.storedResolvedColors!.count { self.storedResolvedColors![index] = color }
			else if index < self.storedColors.count {
				self.storedColors[index] = self.restoredColor(color, forKey: key)
				self.colorSources[key] = self.storedColors[index]
			}
			return
		}
		guard let point = (value as? NSValue)?.cgPointValue else { return }
		if self.storedBezierPoints != nil, index < self.storedBezierPoints!.count {
			switch parts[1] {
			case "point": self.storedBezierPoints![index].position = point
			case "leading": self.storedBezierPoints![index].leadingControlPoint = point
			case "top": self.storedBezierPoints![index].topControlPoint = point
			case "trailing": self.storedBezierPoints![index].trailingControlPoint = point
			case "bottom": self.storedBezierPoints![index].bottomControlPoint = point
			default: break
			}
		}
		else if parts[1] == "point", index < self.storedPoints.count { self.storedPoints[index] = point }
	}

	private func restoredColor(_ color: CGColor, forKey key: String) -> UIColor {
		self.animationColorSources[key]?.last(where: { $0.0 == color })?.1 ?? UIColor(cgColor: color)
	}

	private func updateMesh(resolvesColors: Bool = true) {
		let shouldResolveColors = resolvesColors || self.traitCollection.hasDifferentColorAppearance(comparedTo: self.resolvedTraits)
		self.resolvedTraits = self.traitCollection
		let size: MeshSize = self.meshSize
		let vertices: [BezierPoint] = self.bezierPoints ?? MeshGeometry.automaticVertices(points: self.points, size: size)
		if shouldResolveColors {
			self.cachedColors = self.resolvedColors ?? self.colors.map({ $0.resolvedColor(with: self.traitCollection).cgColor })
			self.cachedRGBAColors = self.cachedColors.map(MeshGeometry.rgba)
			self.cachedBackground = self.meshBackgroundColor.resolvedColor(with: self.traitCollection).cgColor
			self.cachedRGBABackground = MeshGeometry.rgba(self.cachedBackground)
		}
		let colors = self.cachedColors
		var error: String?
		if size.width < 2 || size.height < 2 || size.vertexCount <= 0 || size.vertexCount > 4096 {
			error = "Mesh dimensions must be at least 2 × 2, with at most 4096 vertices."
		}
		else if vertices.count != size.vertexCount || colors.count != size.vertexCount {
			error = "Positions and colors must each contain meshSize.width × meshSize.height elements."
		}
		else if vertices.contains(where: { v in
			!v.position.x.isFinite || !v.position.y.isFinite || !v.leadingControlPoint.x.isFinite || !v.leadingControlPoint.y.isFinite ||
				!v.topControlPoint.x.isFinite || !v.topControlPoint.y.isFinite || !v.trailingControlPoint.x.isFinite || !v.trailingControlPoint.y.isFinite ||
				!v.bottomControlPoint.x.isFinite || !v.bottomControlPoint.y.isFinite
		}) {
			error = "All mesh positions and handles must be finite."
		}
		self.configurationError = error
		self.meshLayer.meshSize = size
		self.meshLayer.isValid = error == nil
		self.meshLayer.smoothsColors = self.smoothsColors
		self.meshLayer.colorSpace = self.colorSpace
		self.meshLayer.debugMode = self.debugMode
		self.meshLayer.subdivisions = min(128, max(0, self.subdivisions))
		self.meshLayer.maximumGeometryError = self.maximumGeometryError.isFinite ? Float(min(8, max(0.05, self.maximumGeometryError))) : 0.5
		let mesh: MeshGeometry.Snapshot? = error == nil ? .init(size: size, vertices: vertices, colors: self.cachedRGBAColors,
			background: self.cachedRGBABackground, smoothsColors: self.smoothsColors, colorSpace: self.colorSpace,
			debugMode: self.debugMode, subdivisions: self.meshLayer.subdivisions, maximumGeometryError: self.meshLayer.maximumGeometryError) : nil
		let action: CAAction? = self.meshLayer.needsMeshWrite(mesh) && !CATransaction.disableActions() && UIView.areAnimationsEnabled ? super.action(for: self.meshLayer, forKey: "backgroundColor") : nil
		self.configurationAnimationTemplate = action
		self.meshLayer.configure(mesh, colors: colors, background: self.cachedBackground, animates: action != nil && !(action is NSNull))
		self.configurationAnimationTemplate = nil
		if shouldResolveColors {
			for index in colors.indices { self.colorSources["mesh_color_\(index)"] = self.resolvedColors == nil ? self.colors[index] : nil }
			self.colorSources["mesh_background"] = self.meshBackgroundColor
		}
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
