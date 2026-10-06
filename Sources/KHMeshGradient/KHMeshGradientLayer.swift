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
	/// Declared dynamic properties drive redisplay reliably, including on OS versions
	/// where arbitrary KVC keys interpolate without generating display callbacks.
	@NSManaged var redrawProgress: CGFloat
	private var renderer: MeshRenderer?
	private var retryIsScheduled: Bool = false
	private var lastSnapshot: MeshGeometry.Snapshot?
	private var lastDrawableSize: CGSize = .zero
	private var hasRendered: Bool = false

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
		self.setValue(value, forKey: key)
	}

	func removeMeshAnimations() {
		for key in self.animationKeys() ?? [] {
			if let animation: CAPropertyAnimation = self.animation(forKey: key) as? CAPropertyAnimation,
				let path: String = animation.keyPath, Self.isMeshKey(path) { self.removeAnimation(forKey: key) }
		}
		for key in self.animationKeys() ?? [] where key.hasPrefix("redraw_") { self.removeAnimation(forKey: key) }
	}

	override func add(_ animation: CAAnimation, forKey key: String?) {
		super.add(animation, forKey: key)
		guard let property: CAPropertyAnimation = animation as? CAPropertyAnimation,
			let path: String = property.keyPath, Self.isMeshKey(path) else { return }
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
		let displayed: KHMeshGradientLayer = target.presentation() ?? target
		let snapshot: MeshGeometry.Snapshot? = displayed.snapshot()
		if target.hasRendered && snapshot == target.lastSnapshot && target.drawableSize == target.lastDrawableSize { return }
		guard let drawable: CAMetalDrawable = target.nextDrawable() else {
			target.scheduleDrawableRetry()
			return
		}
		do {
			let command: MTLCommandBuffer = try renderer.draw(snapshot, texture: drawable.texture)
			// Synchronize Metal presentation with the UIKit/Core Animation transaction.
			// For presentsWithTransaction, present the drawable directly after scheduling.
			command.waitUntilScheduled()
			drawable.present()
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
