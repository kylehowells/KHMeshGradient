import Metal
import UIKit
import simd

final class MeshRenderer {
	static let shared: Result<MeshRenderer, Error> = Result(catching: { try MeshRenderer() })
	let device: MTLDevice
	private let queue: MTLCommandQueue
	private let library: MTLLibrary
	private let maximumRenderTargets: Int
	private struct PipelineKey: Hashable { var target: Int; var count: Int; var debug: Bool; var halfColors: Bool }
	private var pipelines: [PipelineKey: MTLRenderPipelineState] = [:]
	private var pipelineOrder: [PipelineKey] = []
	private let bufferPool: MeshBufferPool
	private var indexBuffers: [Int: MTLBuffer] = [:]
	private var indexBufferOrder: [Int] = []
	private var pendingFrame: Frame?
	private final class LayerReference {
		weak var layer: KHMeshGradientLayer?
		init(_ layer: KHMeshGradientLayer) { self.layer = layer }
	}

	private var layers: [LayerReference] = []
	private var isGatheringFrame: Bool = false
	private(set) var submittedBatchCount: UInt64 = 0

	private final class Frame {
		let command: MTLCommandBuffer
		let arena: MeshBufferArena
		var draws: [Draw] = []
		init(command: MTLCommandBuffer, pool: MeshBufferPool) { self.command = command; self.arena = MeshBufferArena(pool: pool) }
	}

	private struct Draw {
		let drawable: CAMetalDrawable?
		let texture: MTLTexture
		let mesh: MeshGeometry.Snapshot?
		let colorNets: MeshGeometry.FragmentColors?
		let statistics: MeshRenderingStatisticsStore?
		let snapshotSeconds: Double
		let drawableSeconds: Double
		var encodingSeconds: Double
		var renderPassShare: Double = 1
		var subdivisionCount: Int = 0
		var triangleCount: UInt64 = 0
		let didFail: (Error) -> Void
		let didSubmit: () -> Void
	}

	struct DebugVertex {
		var position: SIMD2<Float>
		var padding: SIMD2<Float> = .zero
		var color: SIMD4<Float>
	}

	enum Failure: Error, LocalizedError {
		case metalUnavailable
		case shaderMissing
		case resourceAllocation
		case invalidImageSize
		case commandFailed(String)
		var errorDescription: String? {
			switch self {
				case .metalUnavailable: return "Metal is unavailable on this device."

				case .shaderMissing: return "The KHMeshGradient shader resource is missing."

				case .resourceAllocation: return "Metal could not allocate a rendering resource."

				case .invalidImageSize: return "The requested image size is invalid or exceeds the Metal texture limit."

				case let .commandFailed(message): return "Metal rendering failed: \(message)"
			}
		}
	}

	private init() throws {
		guard let device: MTLDevice = MTLCreateSystemDefaultDevice(), let queue: MTLCommandQueue = device.makeCommandQueue() else {
			throw Failure.metalUnavailable
		}

		let library: MTLLibrary
		if let compiled: MTLLibrary = try? device.makeDefaultLibrary(bundle: Bundle.module) {
			library = compiled
		}
		else {
			guard let url: URL = Bundle.module.url(forResource: "MeshShaders", withExtension: "metal") else { throw Failure.shaderMissing }

			library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
		}

		self.device = device
		self.queue = queue
		self.bufferPool = MeshBufferPool(device: device)
		self.library = library
		self.maximumRenderTargets = device.supportsFamily(.apple2) || device.supportsFamily(.mac1) ? 8 : 1
		_ = try self.pipeline(target: 0, count: 1, debug: false)
		_ = try self.pipeline(target: 0, count: 1, debug: true)
	}

	private func pipeline(target: Int, count: Int, debug: Bool, halfColors: Bool = false) throws -> MTLRenderPipelineState {
		let key = PipelineKey(target: target, count: count, debug: debug, halfColors: halfColors)
		if let cached = self.pipelines[key] {
			self.pipelineOrder.removeAll(where: { $0 == key })
			self.pipelineOrder.append(key)
			return cached
		}
		let descriptor = MTLRenderPipelineDescriptor()
		let prefix = debug ? "debug" : "mesh"
		let fragment = "\(prefix)_fragment" + (target == 0 ? "" : "_\(target)")
		descriptor.vertexFunction = self.library.makeFunction(name: "\(prefix)_vertex")
		if debug { descriptor.fragmentFunction = self.library.makeFunction(name: fragment) }
		else {
			let constants = MTLFunctionConstantValues()
			var halfColors = halfColors
			constants.setConstantValue(&halfColors, type: .bool, index: 0)
			descriptor.fragmentFunction = try self.library.makeFunction(name: fragment, constantValues: constants)
		}
		for index in 0 ..< count {
			let attachment: MTLRenderPipelineColorAttachmentDescriptor = descriptor.colorAttachments[index]
			attachment.pixelFormat = .bgra8Unorm
			attachment.writeMask = index == target ? .all : []
			attachment.isBlendingEnabled = debug && index == target
			attachment.sourceRGBBlendFactor = .one
			attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
			attachment.sourceAlphaBlendFactor = .one
			attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
		}
		let pipeline = try self.device.makeRenderPipelineState(descriptor: descriptor)
		if self.pipelineOrder.count == 32 { self.pipelines[self.pipelineOrder.removeFirst()] = nil }
		self.pipelines[key] = pipeline
		self.pipelineOrder.append(key)
		return pipeline
	}

	private func makeFrame() throws -> Frame {
		guard let command = self.queue.makeCommandBuffer() else { throw Failure.resourceAllocation }

		command.label = "KHMeshGradient batch"
		return Frame(command: command, pool: self.bufferPool)
	}

	func enqueue(_ mesh: MeshGeometry.Snapshot?, colorNets: MeshGeometry.FragmentColors?, drawable: CAMetalDrawable, statistics: MeshRenderingStatisticsStore?,
	             snapshotSeconds: Double, drawableSeconds: Double, didFail: @escaping (Error) -> Void, didSubmit: @escaping () -> Void) throws
	{
		if self.pendingFrame == nil { self.pendingFrame = try self.makeFrame() }
		let frame = self.pendingFrame!
		frame.draws.append(Draw(drawable: drawable, texture: drawable.texture, mesh: mesh, colorNets: colorNets, statistics: statistics, snapshotSeconds: snapshotSeconds,
		                        drawableSeconds: drawableSeconds, encodingSeconds: 0, didFail: didFail, didSubmit: didSubmit))
	}

	func register(_ layer: KHMeshGradientLayer) {
		self.layers.removeAll(where: { $0.layer == nil })
		self.layers.append(LayerReference(layer))
	}

	/// The first dirty layer's display callback gathers the remaining dirty or
	/// animating layers and submits them before that same CA transaction finishes.
	func finishDisplay(for layer: KHMeshGradientLayer) {
		guard !self.isGatheringFrame else { return }

		self.isGatheringFrame = true
		defer { self.isGatheringFrame = false }
		self.layers.removeAll(where: { $0.layer == nil })
		for reference in self.layers {
			guard let other = reference.layer, other !== layer, other.isRenderingEnabled else { continue }

			if other.isMeshDisplayPending || other.hasMeshAnimations { other.enqueueFrameIfNeeded() }
		}
		while self.pendingFrame != nil {
			self.flush()
		}
	}

	func flush() {
		autoreleasepool(invoking: { self.submitPendingFrame() })
	}

	private func submitPendingFrame() {
		guard let frame = self.pendingFrame else { return }

		self.pendingFrame = nil
		guard !frame.draws.isEmpty else { self.bufferPool.recycle(frame.arena.buffers); return }

		do { try self.encodeBatch(frame) }
		catch {
			for draw in frame.draws {
				draw.didFail(error)
			}
			self.bufferPool.recycle(frame.arena.buffers)
			return
		}
		let share = 1 / Double(frame.draws.count)
		let stores = frame.draws.compactMap({ $0.statistics })
		let buffers = frame.arena.buffers
		let pool = self.bufferPool
		frame.command.addCompletedHandler({ command in
			for store in stores {
				store.recordGPU(command, share: share)
			}
			pool.recycle(buffers)
		})
		let measures = !stores.isEmpty
		let start = measures ? CACurrentMediaTime() : 0
		frame.command.commit()
		frame.command.waitUntilScheduled()
		for draw in frame.draws {
			#if !targetEnvironment(simulator)
				if let store = draw.statistics { draw.drawable?.addPresentedHandler({ drawable in store.recordPresentation(drawable) }) }
			#endif
			draw.drawable?.present()
		}
		let scheduling = measures ? (CACurrentMediaTime() - start) * share : 0
		self.submittedBatchCount += 1
		for draw in frame.draws {
			draw.statistics?.recordCPU(total: draw.snapshotSeconds + draw.drawableSeconds + draw.encodingSeconds + scheduling,
			                           snapshot: draw.snapshotSeconds, drawable: draw.drawableSeconds, encoding: draw.encodingSeconds,
			                           scheduling: scheduling, commandBuffers: share, renderPasses: draw.renderPassShare,
			                           subdivisions: draw.subdivisionCount, triangles: draw.triangleCount)
			draw.didSubmit()
		}
	}

	private func indices(subdivisions: Int) throws -> MTLBuffer {
		if let buffer = self.indexBuffers[subdivisions] {
			self.indexBufferOrder.removeAll(where: { $0 == subdivisions })
			self.indexBufferOrder.append(subdivisions)
			return buffer
		}
		var indices: [UInt32] = []
		indices.reserveCapacity(6 * subdivisions * subdivisions)
		let row = UInt32(subdivisions + 1)
		for y in 0 ..< subdivisions {
			for x in 0 ..< subdivisions {
				let a = UInt32(y) * row + UInt32(x)
				indices.append(contentsOf: [a, a + 1, a + row, a + 1, a + row + 1, a + row])
			}
		}
		guard let buffer = indices.withUnsafeBytes({ bytes in self.device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared) }) else { throw Failure.resourceAllocation }

		buffer.label = "KHMeshGradient shared triangle indices"
		if self.indexBufferOrder.count == 8 { self.indexBuffers[self.indexBufferOrder.removeFirst()] = nil }
		self.indexBufferOrder.append(subdivisions)
		self.indexBuffers[subdivisions] = buffer
		return buffer
	}

	private func encodeMesh(_ mesh: MeshGeometry.Snapshot?, encoder: MTLRenderCommandEncoder, arena: MeshBufferArena, pixels: SIMD2<Float>, colorNets: MeshGeometry.FragmentColors? = nil, target: Int = 0, targetCount: Int = 1) throws -> Int {
		if let mesh: MeshGeometry.Snapshot = mesh {
			let patches: [SIMD4<Float>] = MeshGeometry.positionPatchData(mesh)
			let count = MeshGeometry.subdivisionCount(mesh, patches: patches, pixels: pixels, positionStride: 16)
			let colors = colorNets ?? MeshGeometry.fragmentColorCoefficients(mesh)
			let upload: (buffer: MTLBuffer, offset: Int)
			let colorUpload: (buffer: MTLBuffer, offset: Int)
			let indices: MTLBuffer
			do {
				upload = try arena.upload(patches)
				switch colors {
					case let .half(data): colorUpload = try arena.upload(data)

					case let .float(data): colorUpload = try arena.upload(data)
				}
				indices = try self.indices(subdivisions: count)
			}
			catch { throw error }
			var subdivisions: UInt32 = UInt32(count)
			var space: UInt32 = UInt32(mesh.colorSpace.rawValue)
			try encoder.setRenderPipelineState(self.pipeline(target: target, count: targetCount, debug: false, halfColors: colors.usesHalf))
			encoder.setVertexBuffer(upload.buffer, offset: upload.offset, index: 0)
			encoder.setVertexBytes(&subdivisions, length: MemoryLayout<UInt32>.size, index: 1)
			encoder.setFragmentBytes(&space, length: MemoryLayout<UInt32>.size, index: 0)
			encoder.setFragmentBuffer(colorUpload.buffer, offset: colorUpload.offset, index: 1)
			encoder.drawIndexedPrimitives(type: .triangle, indexCount: 6 * count * count,
			                              indexType: .uint32, indexBuffer: indices, indexBufferOffset: 0, instanceCount: (mesh.size.width - 1) * (mesh.size.height - 1))
			if mesh.debugMode != .none {
				let debug: [DebugVertex] = self.debugVertices(mesh, patches: patches, pixels: pixels, subdivisions: count)
				if !debug.isEmpty {
					let debugUpload: (buffer: MTLBuffer, offset: Int)
					do { debugUpload = try arena.upload(debug) }
					catch { throw error }
					try encoder.setRenderPipelineState(self.pipeline(target: target, count: targetCount, debug: true))
					encoder.setVertexBuffer(debugUpload.buffer, offset: debugUpload.offset, index: 0)
					encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: debug.count)
				}
			}
			return count
		}
		return 0
	}

	private func encodeBatch(_ frame: Frame) throws {
		struct TargetSize: Hashable { var width: Int; var height: Int }
		var groups: [[Int]] = []
		var currentGroups: [TargetSize: Int] = [:]
		let measured = frame.draws.contains(where: { $0.statistics != nil })
		let batchStart = measured ? CACurrentMediaTime() : 0
		for index in frame.draws.indices {
			let texture = frame.draws[index].texture
			let key = TargetSize(width: texture.width, height: texture.height)
			if let group = currentGroups[key], groups[group].count < self.maximumRenderTargets { groups[group].append(index) }
			else { currentGroups[key] = groups.count; groups.append([index]) }
		}
		for group in groups {
			let pass = MTLRenderPassDescriptor()
			for (target, index) in group.enumerated() {
				let draw = frame.draws[index]
				let attachment: MTLRenderPassColorAttachmentDescriptor = pass.colorAttachments[target]
				attachment.texture = draw.texture
				attachment.loadAction = .clear
				attachment.storeAction = .store
				let color = draw.mesh?.background ?? .zero
				attachment.clearColor = MTLClearColor(red: Double(color.x * color.w), green: Double(color.y * color.w), blue: Double(color.z * color.w), alpha: Double(color.w))
				frame.draws[index].renderPassShare = 1 / Double(group.count)
			}
			guard let encoder = frame.command.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.resourceAllocation }

			encoder.label = "KHMeshGradient \(group.count) independent render targets"
			do {
				for (target, index) in group.enumerated() {
					let draw = frame.draws[index]
					let start = measured ? CACurrentMediaTime() : 0
					let subdivisions = try self.encodeMesh(draw.mesh, encoder: encoder, arena: frame.arena,
					                                       pixels: SIMD2<Float>(Float(draw.texture.width), Float(draw.texture.height)), colorNets: draw.colorNets, target: target, targetCount: group.count)
					frame.draws[index].subdivisionCount = subdivisions
					let patchCount = draw.mesh.map({ ($0.size.width - 1) * ($0.size.height - 1) }) ?? 0
					frame.draws[index].triangleCount = UInt64(2 * subdivisions * subdivisions * patchCount)
					frame.draws[index].encodingSeconds = measured ? CACurrentMediaTime() - start : 0
				}
				encoder.endEncoding()
			}
			catch { encoder.endEncoding(); throw error }
		}
		if measured {
			let drawTime = frame.draws.reduce(0, { $0 + $1.encodingSeconds })
			let shared = max(0, CACurrentMediaTime() - batchStart - drawTime) / Double(frame.draws.count)
			for index in frame.draws.indices {
				frame.draws[index].encodingSeconds += shared
			}
		}
	}

	/// The same encoder serves offscreen exports and batch pixel validation.
	func render(_ meshes: [MeshGeometry.Snapshot?], into textures: [MTLTexture]) throws -> MTLCommandBuffer {
		guard meshes.count == textures.count, !meshes.isEmpty else { throw Failure.invalidImageSize }

		let frame = try self.makeFrame()
		frame.draws = meshes.indices.map({ index in
			Draw(drawable: nil, texture: textures[index], mesh: meshes[index], colorNets: nil, statistics: nil,
			     snapshotSeconds: 0, drawableSeconds: 0, encodingSeconds: 0, didFail: { error in }, didSubmit: { })
		})
		try self.encodeBatch(frame)
		let pool = self.bufferPool
		let buffers = frame.arena.buffers
		frame.command.addCompletedHandler({ command in pool.recycle(buffers) })
		frame.command.commit()
		return frame.command
	}

	func image(_ mesh: MeshGeometry.Snapshot, size: CGSize, scale: CGFloat) throws -> UIImage {
		let pixelWidth: CGFloat = (size.width * scale).rounded(.up)
		let pixelHeight: CGFloat = (size.height * scale).rounded(.up)
		guard scale.isFinite, scale > 0, pixelWidth.isFinite, pixelHeight.isFinite,
		      pixelWidth >= 1, pixelHeight >= 1, pixelWidth <= 16384, pixelHeight <= 16384 else { throw Failure.invalidImageSize }

		let width: Int = Int(pixelWidth)
		let height: Int = Int(pixelHeight)
		let descriptor: MTLTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
		descriptor.usage = .renderTarget
		descriptor.storageMode = .shared
		guard let texture: MTLTexture = self.device.makeTexture(descriptor: descriptor) else { throw Failure.resourceAllocation }

		let command: MTLCommandBuffer = try self.render([mesh], into: [texture])
		command.waitUntilCompleted()
		if let error: Error = command.error { throw Failure.commandFailed(error.localizedDescription) }
		var bytes: [UInt8] = [UInt8](repeating: 0, count: width * height * 4)
		texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
		let data: CFData = Data(bytes) as CFData
		guard let provider: CGDataProvider = CGDataProvider(data: data), let image: CGImage = CGImage(
			width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
			space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue:
				CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
			provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
		) else { throw Failure.resourceAllocation }

		return UIImage(cgImage: image, scale: scale, orientation: .up)
	}

	private func debugVertices(_ mesh: MeshGeometry.Snapshot, patches: [SIMD4<Float>], pixels: SIMD2<Float>, subdivisions: Int) -> [DebugVertex] {
		var vertices: [DebugVertex] = []
		let white: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 0.9)
		let black: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0.8)
		func line(_ a: SIMD2<Float>, _ b: SIMD2<Float>, color: SIMD4<Float>, thickness: Float = 1.5) {
			let delta: SIMD2<Float> = (b - a) * pixels
			guard simd_length_squared(delta) > 0.0001 else { return }

			let normal: SIMD2<Float> = simd_normalize(SIMD2<Float>(-delta.y, delta.x)) * thickness * 0.5 / pixels
			for p in [a - normal, b - normal, a + normal, b - normal, b + normal, a + normal] {
				vertices.append(DebugVertex(position: p, color: color))
			}
		}
		func dot(_ p: SIMD2<Float>, radius: Float, color: SIMD4<Float>) {
			for i in 0 ..< 20 {
				let a: Float = Float(i) * .pi / 10
				let b: Float = Float(i + 1) * .pi / 10
				for v in [p, p + SIMD2<Float>(cos(a), sin(a)) * radius / pixels, p + SIMD2<Float>(cos(b), sin(b)) * radius / pixels] {
					vertices.append(DebugVertex(position: v, color: color))
				}
			}
		}
		let count: Int = patches.count / 16
		for patch in 0 ..< count {
			let net: [SIMD4<Float>] = Array(patches[(patch * 16) ..< (patch * 16 + 16)])
			let tracks: [Float] = mesh.debugMode == .tessellation ? (0 ... subdivisions).map({ Float($0) / Float(subdivisions) }) : [0, 1]
			let segments = mesh.debugMode == .tessellation ? subdivisions : 48
			for track in tracks {
				for axis in 0 ..< 2 {
					var previous: SIMD2<Float>?
					for step in 0 ... segments {
						let t: Float = Float(step) / Float(segments)
						let p: SIMD4<Float> = MeshGeometry.evaluate(net, u: axis == 0 ? t : track, v: axis == 0 ? track : t)
						let point: SIMD2<Float> = SIMD2<Float>(p.x, p.y)
						if let previous: SIMD2<Float> = previous {
							line(previous, point, color: black, thickness: 3)
							line(previous, point, color: white)
						}
						previous = point
					}
				}
			}
			if mesh.debugMode == .tessellation {
				for y in 0 ..< subdivisions {
					for x in 0 ..< subdivisions {
						let a = MeshGeometry.evaluate(net, u: Float(x + 1) / Float(subdivisions), v: Float(y) / Float(subdivisions))
						let b = MeshGeometry.evaluate(net, u: Float(x) / Float(subdivisions), v: Float(y + 1) / Float(subdivisions))
						line(SIMD2<Float>(a.x, a.y), SIMD2<Float>(b.x, b.y), color: black, thickness: 2)
						line(SIMD2<Float>(a.x, a.y), SIMD2<Float>(b.x, b.y), color: white, thickness: 1)
					}
				}
			}
		}
		for (index, vertex) in mesh.vertices.enumerated() {
			let p: SIMD2<Float> = MeshGeometry.vector(vertex.position)
			if mesh.debugMode == .controlPoints {
				let x: Int = index % mesh.size.width
				let y: Int = index / mesh.size.width
				var handles: [CGPoint] = []
				if x > 0 { handles.append(vertex.leadingControlPoint) }
				if x + 1 < mesh.size.width { handles.append(vertex.trailingControlPoint) }
				if y > 0 { handles.append(vertex.topControlPoint) }
				if y + 1 < mesh.size.height { handles.append(vertex.bottomControlPoint) }
				for handle in handles {
					let h: SIMD2<Float> = MeshGeometry.vector(handle)
					line(p, h, color: SIMD4<Float>(1, 0.85, 0.2, 1))
					dot(h, radius: 3, color: SIMD4<Float>(1, 0.85, 0.2, 1))
				}
			}
			dot(p, radius: 6, color: black)
			dot(p, radius: 4.5, color: white)
			dot(p, radius: 3, color: mesh.colors[index])
		}
		return vertices
	}
}
