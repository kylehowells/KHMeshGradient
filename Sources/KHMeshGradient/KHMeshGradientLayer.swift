import Metal
import UIKit

/// Static configuration uses a cached model snapshot; animated values use KVC
/// so presentation copies interpolate. Model layers share GPU submission batches.
final class KHMeshGradientLayer: CAMetalLayer {
	var meshSize: KHMeshGradientView.MeshSize = .init(width: 2, height: 2)
	var smoothsColors: Bool = true
	var colorSpace: KHMeshGradientView.ColorSpace = .device
	var debugMode: KHMeshGradientView.DebugMode = .none
	var subdivisions: Int = 0
	var maximumGeometryError: Float = 0.5
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
	private struct ColorKey: Equatable {
		var size: KHMeshGradientView.MeshSize
		var colors: [SIMD4<Float>]
		var smoothsColors: Bool
		var colorSpace: KHMeshGradientView.ColorSpace
	}
	private var colorKey: ColorKey?
	private var colorNets: MeshGeometry.FragmentColors?
	private var lastDrawableSize: CGSize = .zero
	private var hasRendered: Bool = false
	private(set) var isMeshDisplayPending: Bool = true
	var modelValueDidChange: ((String, Any?) -> Void)?
	private(set) var isSettingMeshValue: Bool = false
	private(set) var isSeedingMeshValues: Bool = false
	private var modelSnapshot: MeshGeometry.Snapshot?
	private var modelColors: [CGColor] = []
	private var modelBackground: CGColor = UIColor.clear.cgColor
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
		// Triple buffering preserves 120 Hz transaction-synchronized presentation.
		self.maximumDrawableCount = 3
		self.presentsWithTransaction = true
		self.needsDisplayOnBoundsChange = true
		self.redrawProgress = 0
		self.renderer?.register(self)
	}

	override init(layer: Any) {
		super.init(layer: layer)
		if let source: KHMeshGradientLayer = layer as? KHMeshGradientLayer {
			self.meshSize = source.meshSize
			self.smoothsColors = source.smoothsColors
			self.colorSpace = source.colorSpace
			self.debugMode = source.debugMode
			self.subdivisions = source.subdivisions
			self.maximumGeometryError = source.maximumGeometryError
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
		if !self.isSettingMeshValue && Self.isMeshKey(key) {
			self.restoreSnapshotValue(value, forKey: key)
			self.modelValueDidChange?(key, value)
		}
	}

	func needsMeshWrite(_ mesh: MeshGeometry.Snapshot?) -> Bool {
		guard let mesh, let previous = self.modelSnapshot, mesh.size == previous.size else { return false }
		return mesh.vertices != previous.vertices || mesh.colors != previous.colors || mesh.background != previous.background
	}

	/// Static updates retain an immutable model snapshot. KVC is populated lazily
	/// when an animation begins, and remains coherent while other keys animate.
	func configure(_ mesh: MeshGeometry.Snapshot?, colors: [CGColor], background: CGColor, animates: Bool) {
		defer { self.modelSnapshot = mesh; self.modelColors = colors; self.modelBackground = background }
		guard let mesh, let previous = self.modelSnapshot, mesh.size == previous.size else {
			self.removeMeshAnimations()
			return
		}
		let active = self.hasMeshAnimations
		if !animates && !active { return }
		if animates && !active {
			self.isSeedingMeshValues = true
			self.writeMeshValues(previous, colors: self.modelColors, background: self.modelBackground, previous: nil)
			self.isSeedingMeshValues = false
		}
		self.writeMeshValues(mesh, colors: colors, background: background, previous: previous)
	}

	private func writeMeshValues(_ mesh: MeshGeometry.Snapshot, colors: [CGColor], background: CGColor, previous: MeshGeometry.Snapshot?) {
		for (index, vertex) in mesh.vertices.enumerated() {
			let old = previous?.vertices[index]
			func write(_ point: CGPoint, old: CGPoint?, name: String) {
				if point != old { self.setMeshValue(NSValue(cgPoint: point), forKey: "mesh_\(name)_\(index)") }
			}
			write(vertex.position, old: old?.position, name: "point")
			write(vertex.leadingControlPoint, old: old?.leadingControlPoint, name: "leading")
			write(vertex.topControlPoint, old: old?.topControlPoint, name: "top")
			write(vertex.trailingControlPoint, old: old?.trailingControlPoint, name: "trailing")
			write(vertex.bottomControlPoint, old: old?.bottomControlPoint, name: "bottom")
			if mesh.colors[index] != previous?.colors[index] { self.setMeshValue(colors[index], forKey: "mesh_color_\(index)") }
		}
		if mesh.background != previous?.background { self.setMeshValue(background, forKey: "mesh_background") }
	}

	private func restoreSnapshotValue(_ value: Any?, forKey key: String) {
		if key == "mesh_background", let color = value as! CGColor? {
			self.modelBackground = color
			self.modelSnapshot?.background = MeshGeometry.rgba(color)
			return
		}
		let parts = key.split(separator: "_")
		guard parts.count == 3, let index = Int(parts[2]), index >= 0, let mesh = self.modelSnapshot, index < mesh.vertices.count else { return }
		if parts[1] == "color", let color = value as! CGColor? {
			self.modelColors[index] = color
			self.modelSnapshot?.colors[index] = MeshGeometry.rgba(color)
			return
		}
		guard let point = (value as? NSValue)?.cgPointValue else { return }
		switch parts[1] {
		case "point": self.modelSnapshot?.vertices[index].position = point
		case "leading": self.modelSnapshot?.vertices[index].leadingControlPoint = point
		case "top": self.modelSnapshot?.vertices[index].topControlPoint = point
		case "trailing": self.modelSnapshot?.vertices[index].trailingControlPoint = point
		case "bottom": self.modelSnapshot?.vertices[index].bottomControlPoint = point
		default: break
		}
	}

	var hasMeshAnimations: Bool {
		(self.animationKeys() ?? []).contains(where: { key in
			if key.hasPrefix("mesh_") || key.hasPrefix("redraw_") { return true }
			guard let animation = self.animation(forKey: key) as? CAPropertyAnimation, let path = animation.keyPath else { return false }
			return Self.isMeshKey(path)
		})
	}

	func displayedSnapshot() -> MeshGeometry.Snapshot? {
		self.hasMeshAnimations ? (self.presentation() ?? self).snapshot() : self.snapshot()
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
		if self === self.model() { return self.modelSnapshot }
		guard self.isValid, self.meshSize.vertexCount >= 4 else { return nil }
		let model: KHMeshGradientLayer = self.model()
		var vertices: [KHMeshGradientView.BezierPoint] = []
		var colors: [SIMD4<Float>] = []
		vertices.reserveCapacity(self.meshSize.vertexCount)
		colors.reserveCapacity(self.meshSize.vertexCount)
		for index in 0..<self.meshSize.vertexCount {
			func point(_ name: String) -> CGPoint? { (self.value(forKey: "mesh_\(name)_\(index)") as? NSValue)?.cgPointValue }
			guard let p: CGPoint = point("point"), let l: CGPoint = point("leading"), let t: CGPoint = point("top"),
				let r: CGPoint = point("trailing"), let b: CGPoint = point("bottom"),
				let c: CGColor = self.value(forKey: "mesh_color_\(index)") as! CGColor? else { return nil }
			vertices.append(.init(position: p, leadingControlPoint: l, topControlPoint: t, trailingControlPoint: r, bottomControlPoint: b))
			if index < model.modelColors.count, model.modelColors[index] == c, let cached = model.modelSnapshot?.colors[index] { colors.append(cached) }
			else { colors.append(MeshGeometry.rgba(c)) }
		}
		let background: CGColor? = self.value(forKey: "mesh_background") as! CGColor?
		let backgroundRGBA = background == model.modelBackground ? (model.modelSnapshot?.background ?? .zero) : (background.map(MeshGeometry.rgba) ?? .zero)
		return MeshGeometry.Snapshot(size: self.meshSize, vertices: vertices, colors: colors,
			background: backgroundRGBA, smoothsColors: model.smoothsColors,
			colorSpace: model.colorSpace, debugMode: model.debugMode, subdivisions: model.subdivisions, maximumGeometryError: model.maximumGeometryError)
	}

	override func setNeedsDisplay() {
		self.isMeshDisplayPending = true
		super.setNeedsDisplay()
	}

	override func display() { self.model().enqueueFrameIfNeeded() }

	func enqueueFrameIfNeeded() {
		let target: KHMeshGradientLayer = self.model()
		guard target.isRenderingEnabled, target.drawableSize.width > 0, target.drawableSize.height > 0,
			let renderer: MeshRenderer = target.renderer else { return }
		target.isMeshDisplayPending = false
		let statistics: MeshRenderingStatisticsStore? = target.collectsRenderingStatistics ? target.statisticsStore : nil
		let start: Double = statistics != nil ? CACurrentMediaTime() : 0
		// Static setters can invalidate before the presentation tree reflects the new
		// model value. Only sample that tree while a mesh animation is actually active.
		let snapshot: MeshGeometry.Snapshot? = target.displayedSnapshot()
		if target.hasRendered && snapshot == target.lastSnapshot && target.drawableSize == target.lastDrawableSize { return }
		if let mesh = snapshot {
			let key = ColorKey(size: mesh.size, colors: mesh.colors, smoothsColors: mesh.smoothsColors, colorSpace: mesh.colorSpace)
			if target.colorKey != key {
				target.colorNets = MeshGeometry.fragmentColorCoefficients(mesh)
				target.colorKey = key
			}
		}
		else { target.colorNets = nil; target.colorKey = nil }
		let snapshotEnd: Double = statistics != nil ? CACurrentMediaTime() : 0
		guard let drawable: CAMetalDrawable = target.nextDrawable() else {
			target.scheduleDrawableRetry()
			return
		}
		let drawableEnd: Double = statistics != nil ? CACurrentMediaTime() : 0
		do {
			try renderer.enqueue(snapshot, colorNets: target.colorNets, drawable: drawable, statistics: statistics,
				snapshotSeconds: snapshotEnd - start, drawableSeconds: drawableEnd - snapshotEnd, didFail: { [weak target] error in
					target?.renderingError = error
					target?.hasRendered = false
					target?.scheduleDrawableRetry()
				}, didSubmit: { [weak target] in
					target?.renderedFrameCount += 1
				})
			target.lastSnapshot = snapshot
			target.lastDrawableSize = target.drawableSize
			target.hasRendered = true
			target.renderingError = nil
			renderer.finishDisplay(for: target)
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
