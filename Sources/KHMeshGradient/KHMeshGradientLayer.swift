import Metal
import UIKit

/// Dynamic mesh values live in CALayer's KVC storage, so presentation copies hold
/// interpolated values. Only the model layer acquires drawables or submits GPU work.
final class KHMeshGradientLayer: CAMetalLayer {
	var meshSize: KHMeshGradientView.MeshSize = .init(width: 2, height: 2)
	var smoothsColors: Bool = true
	var colorSpace: KHMeshGradientView.ColorSpace = .device
	var debugMode: KHMeshGradientView.DebugMode = .none
	var subdivisions: Int = 48
	var isValid: Bool = true
	var isRenderingEnabled: Bool = false {
		didSet {
			if self.isRenderingEnabled && !oldValue { self.hasRendered = false; self.setNeedsDisplay() }
		}
	}
	var renderedFrameCount: UInt64 = 0
	var renderingError: Error?
	var collectsRenderingStatistics: Bool = false {
		didSet { if self.collectsRenderingStatistics && self.statisticsStore == nil { self.statisticsStore = MeshRenderingStatisticsStore() } }
	}
	private var statisticsStore: MeshRenderingStatisticsStore?
	var renderingStatistics: KHMeshGradientView.RenderingStatistics { self.statisticsStore?.snapshot() ?? .init() }
	func resetRenderingStatistics() { self.statisticsStore = MeshRenderingStatisticsStore() }
	/// Declared dynamic properties drive redisplay reliably, including on OS versions
	/// where arbitrary KVC keys interpolate without generating display callbacks.
	@NSManaged var redrawProgress: CGFloat
	private var renderer: MeshRenderer?
	private var retryIsScheduled: Bool = false
	private var lastSnapshot: MeshGeometry.Snapshot?
	private var lastDrawableSize: CGSize = .zero
	private var hasRendered: Bool = false
	var modelValueDidChange: ((String, Any?) -> Void)?
	private(set) var isSettingMeshValue: Bool = false
	private var actionRoute: (path: String, key: String, from: Any, to: Any?)?
	/// CAAnimation supports custom KVC values, and preserves them in copies.
	private static let managedAnimationMarker = "khMeshAnimatorManaged"

	func runUIKitAction(_ action: CAAction, forKey key: String, storageKey: String? = nil, fromValue: Any, toValue: Any? = nil, arguments: [AnyHashable: Any]?) {
		let previous = self.actionRoute
		self.actionRoute = (key, storageKey ?? key, fromValue, toValue)
		defer { self.actionRoute = previous }
		action.run(forKey: key, object: self, arguments: arguments)
	}

	static func isMeshKey(_ key: String) -> Bool { key.hasPrefix("mesh_") }

	override class func needsDisplay(forKey key: String) -> Bool {
		key == "redrawProgress" || self.isMeshKey(key) || super.needsDisplay(forKey: key)
	}

	override init() {
		super.init()
		do {
			let renderer: MeshRenderer = try MeshRenderer.shared.get()
			self.renderer = renderer
			self.device = renderer.device
		}
		catch { self.renderingError = error }
		self.pixelFormat = .bgra8Unorm
		self.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
		self.isOpaque = false
		self.framebufferOnly = true
		self.presentsWithTransaction = true
		self.needsDisplayOnBoundsChange = true
		self.redrawProgress = 0
	}

	override init(layer: Any) {
		super.init(layer: layer)
		if let source: KHMeshGradientLayer = layer as? KHMeshGradientLayer {
			self.meshSize = source.meshSize
			self.smoothsColors = source.smoothsColors
			self.colorSpace = source.colorSpace
			self.debugMode = source.debugMode
			self.subdivisions = source.subdivisions
			self.isValid = source.isValid
			self.isRenderingEnabled = source.isRenderingEnabled
			self.renderer = source.renderer
		}
	}

	required init?(coder: NSCoder) { super.init(coder: coder) }

	func setMeshValue(_ value: Any, forKey key: String) {
		if let old: NSObject = self.value(forKey: key) as? NSObject, old.isEqual(value) { return }
		self.isSettingMeshValue = true
		defer { self.isSettingMeshValue = false }
		self.setValue(value, forKey: key)
	}

	override func setValue(_ value: Any?, forKey key: String) {
		super.setValue(value, forKey: key)
		if !self.isSettingMeshValue && Self.isMeshKey(key) { self.modelValueDidChange?(key, value) }
	}

	func removeMeshAnimations() {
		for key in self.animationKeys() ?? [] {
			if let animation: CAPropertyAnimation = self.animation(forKey: key) as? CAPropertyAnimation,
				let path: String = animation.keyPath, Self.isMeshKey(path) { self.removeAnimation(forKey: key) }
		}
		for key in self.animationKeys() ?? [] where key.hasPrefix("redraw_") { self.removeAnimation(forKey: key) }
	}

	override func add(_ animation: CAAnimation, forKey key: String?) {
		if let route = self.actionRoute, let basic: CABasicAnimation = animation as? CABasicAnimation,
			basic.keyPath == "backgroundColor" {
			// Keep the original object: UIKit registers it after this override returns.
			// Retarget only the native property animation, leaving helper animations intact.
			basic.keyPath = route.path
			basic.fromValue = route.from
			basic.toValue = route.to ?? self.value(forKey: route.path)
			basic.byValue = nil
			basic.isAdditive = false
			basic.isCumulative = false
			basic.setValue(true, forKey: Self.managedAnimationMarker)
			super.add(basic, forKey: route.key)
			return
		}
		super.add(animation, forKey: key)
		guard let property: CAPropertyAnimation = animation as? CAPropertyAnimation,
			let path: String = property.keyPath, Self.isMeshKey(path) else { return }
		if animation.value(forKey: Self.managedAnimationMarker) as? Bool == true { return }
		let pulse: CABasicAnimation = CABasicAnimation(keyPath: "redrawProgress")
		pulse.fromValue = 0
		pulse.toValue = 1
		pulse.duration = animation.duration
		pulse.beginTime = animation.beginTime
		pulse.speed = animation.speed
		pulse.timeOffset = animation.timeOffset
		pulse.repeatCount = animation.repeatCount
		pulse.repeatDuration = animation.repeatDuration
		pulse.autoreverses = animation.autoreverses
		pulse.fillMode = animation.fillMode
		pulse.isRemovedOnCompletion = animation.isRemovedOnCompletion
		pulse.preferredFrameRateRange = animation.preferredFrameRateRange
		super.add(pulse, forKey: "redraw_\(key ?? path)")
	}

	override func removeAnimation(forKey key: String) {
		super.removeAnimation(forKey: key)
		super.removeAnimation(forKey: "redraw_\(key)")
		self.setNeedsDisplay()
	}

	func snapshot() -> MeshGeometry.Snapshot? {
		guard self.isValid, self.meshSize.vertexCount >= 4 else { return nil }
		var vertices: [KHMeshGradientView.BezierPoint] = []
		var colors: [SIMD4<Float>] = []
		for index in 0..<self.meshSize.vertexCount {
			func point(_ name: String) -> CGPoint? { (self.value(forKey: "mesh_\(name)_\(index)") as? NSValue)?.cgPointValue }
			guard let p: CGPoint = point("point"), let l: CGPoint = point("leading"), let t: CGPoint = point("top"),
				let r: CGPoint = point("trailing"), let b: CGPoint = point("bottom"),
				let c: CGColor = self.value(forKey: "mesh_color_\(index)") as! CGColor? else { return nil }
			vertices.append(.init(position: p, leadingControlPoint: l, topControlPoint: t, trailingControlPoint: r, bottomControlPoint: b))
			colors.append(MeshGeometry.rgba(c))
		}
		let background: CGColor? = self.value(forKey: "mesh_background") as! CGColor?
		return MeshGeometry.Snapshot(size: self.meshSize, vertices: vertices, colors: colors,
			background: background.map(MeshGeometry.rgba) ?? .zero, smoothsColors: self.smoothsColors,
			colorSpace: self.colorSpace, debugMode: self.debugMode, subdivisions: self.subdivisions)
	}

	override func display() {
		let target: KHMeshGradientLayer = self.model()
		guard target.isRenderingEnabled, target.drawableSize.width > 0, target.drawableSize.height > 0,
			let renderer: MeshRenderer = target.renderer else { return }
		let statistics: MeshRenderingStatisticsStore? = target.collectsRenderingStatistics ? target.statisticsStore : nil
		let start: Double = statistics != nil ? CACurrentMediaTime() : 0
		// Static setters can invalidate before the presentation tree reflects the new
		// model value. Only sample that tree while a mesh animation is actually active.
		let hasMeshAnimation: Bool = (target.animationKeys() ?? []).contains(where: { key in
			if key.hasPrefix("mesh_") || key.hasPrefix("redraw_") { return true }
			guard let animation: CAPropertyAnimation = target.animation(forKey: key) as? CAPropertyAnimation,
				let path: String = animation.keyPath else { return false }
			return Self.isMeshKey(path)
		})
		let displayed: KHMeshGradientLayer = hasMeshAnimation ? (target.presentation() ?? target) : target
		let snapshot: MeshGeometry.Snapshot? = displayed.snapshot()
		if target.hasRendered && snapshot == target.lastSnapshot && target.drawableSize == target.lastDrawableSize { return }
		let snapshotEnd: Double = statistics != nil ? CACurrentMediaTime() : 0
		guard let drawable: CAMetalDrawable = target.nextDrawable() else {
			target.scheduleDrawableRetry()
			return
		}
		let drawableEnd: Double = statistics != nil ? CACurrentMediaTime() : 0
		do {
			let command: MTLCommandBuffer = try renderer.draw(snapshot, texture: drawable.texture, statistics: statistics)
			let encodingEnd: Double = statistics != nil ? CACurrentMediaTime() : 0
			// Synchronize Metal presentation with the UIKit/Core Animation transaction.
			// For presentsWithTransaction, present the drawable directly after scheduling.
			command.waitUntilScheduled()
			#if !targetEnvironment(simulator)
			if let statistics: MeshRenderingStatisticsStore = statistics {
				drawable.addPresentedHandler({ drawable in statistics.recordPresentation(drawable) })
			}
			#endif
			drawable.present()
			if let statistics: MeshRenderingStatisticsStore = statistics {
				let end: Double = CACurrentMediaTime()
				statistics.recordCPU(total: end - start, snapshot: snapshotEnd - start,
					drawable: drawableEnd - snapshotEnd, encoding: encodingEnd - drawableEnd, scheduling: end - encodingEnd)
			}
			target.renderedFrameCount += 1
			target.lastSnapshot = snapshot
			target.lastDrawableSize = target.drawableSize
			target.hasRendered = true
			target.renderingError = nil
		}
		catch { target.renderingError = error }
	}

	private func scheduleDrawableRetry() {
		guard !self.retryIsScheduled else { return }
		self.retryIsScheduled = true
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: { [weak self] in
			guard let self: KHMeshGradientLayer = self else { return }
			self.retryIsScheduled = false
			if self.isRenderingEnabled { self.setNeedsDisplay() }
		})
	}
}
