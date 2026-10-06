import Metal
import UIKit
import simd

final class MeshRenderer {
	static let shared: Result<MeshRenderer, Error> = Result(catching: { try MeshRenderer() })
	let device: MTLDevice
	private let queue: MTLCommandQueue
	private let meshPipeline: MTLRenderPipelineState
	private let debugPipeline: MTLRenderPipelineState

	struct DebugVertex {
		var position: SIMD2<Float>
		var padding: SIMD2<Float> = .zero
		var color: SIMD4<Float>
	}

	enum Failure: Error, LocalizedError {
		case metalUnavailable, shaderMissing, resourceAllocation, invalidImageSize, commandFailed(String)
		var errorDescription: String? {
			switch self {
				case .metalUnavailable: return "Metal is unavailable on this device."
				case .shaderMissing: return "The KHMeshGradient shader resource is missing."
				case .resourceAllocation: return "Metal could not allocate a rendering resource."
				case .invalidImageSize: return "The requested image size is invalid or exceeds the Metal texture limit."
				case .commandFailed(let message): return "Metal rendering failed: \(message)"
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
		func pipeline(vertex: String, fragment: String, blends: Bool) throws -> MTLRenderPipelineState {
			let descriptor: MTLRenderPipelineDescriptor = MTLRenderPipelineDescriptor()
			descriptor.vertexFunction = library.makeFunction(name: vertex)
			descriptor.fragmentFunction = library.makeFunction(name: fragment)
			let attachment: MTLRenderPipelineColorAttachmentDescriptor = descriptor.colorAttachments[0]
			attachment.pixelFormat = .bgra8Unorm
			attachment.isBlendingEnabled = blends
			attachment.sourceRGBBlendFactor = .one
			attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
			attachment.sourceAlphaBlendFactor = .one
			attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
			return try device.makeRenderPipelineState(descriptor: descriptor)
		}
		self.device = device
		self.queue = queue
		self.meshPipeline = try pipeline(vertex: "mesh_vertex", fragment: "mesh_fragment", blends: false)
		self.debugPipeline = try pipeline(vertex: "debug_vertex", fragment: "debug_fragment", blends: true)
	}

	func draw(_ mesh: MeshGeometry.Snapshot?, texture: MTLTexture, drawable: CAMetalDrawable? = nil) throws -> MTLCommandBuffer {
		guard let command: MTLCommandBuffer = self.queue.makeCommandBuffer() else { throw Failure.resourceAllocation }
		command.label = "KHMeshGradient frame"
		let pass: MTLRenderPassDescriptor = MTLRenderPassDescriptor()
		pass.colorAttachments[0].texture = texture
		pass.colorAttachments[0].loadAction = .clear
		pass.colorAttachments[0].storeAction = .store
		let background: SIMD4<Float> = mesh?.background ?? .zero
		pass.colorAttachments[0].clearColor = MTLClearColor(
			red: Double(background.x * background.w), green: Double(background.y * background.w),
			blue: Double(background.z * background.w), alpha: Double(background.w)
		)
		guard let encoder: MTLRenderCommandEncoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.resourceAllocation }
		encoder.label = "Bicubic mesh patches"
		if let mesh: MeshGeometry.Snapshot = mesh {
			let patches: [SIMD4<Float>] = MeshGeometry.patchData(mesh)
			guard let buffer: MTLBuffer = patches.withUnsafeBytes({ bytes in
				self.device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
			}) else { encoder.endEncoding(); throw Failure.resourceAllocation }
			var subdivisions: UInt32 = UInt32(mesh.subdivisions)
			var space: UInt32 = UInt32(mesh.colorSpace.rawValue)
			encoder.setRenderPipelineState(self.meshPipeline)
			encoder.setVertexBuffer(buffer, offset: 0, index: 0)
			encoder.setVertexBytes(&subdivisions, length: MemoryLayout<UInt32>.size, index: 1)
			encoder.setFragmentBytes(&space, length: MemoryLayout<UInt32>.size, index: 0)
			encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6 * mesh.subdivisions * mesh.subdivisions,
				instanceCount: (mesh.size.width - 1) * (mesh.size.height - 1))
			if mesh.debugMode != .none {
				let debug: [DebugVertex] = self.debugVertices(mesh, pixels: SIMD2<Float>(Float(texture.width), Float(texture.height)))
				if !debug.isEmpty, let debugBuffer: MTLBuffer = debug.withUnsafeBytes({ bytes in
					self.device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
				}) {
					encoder.setRenderPipelineState(self.debugPipeline)
					encoder.setVertexBuffer(debugBuffer, offset: 0, index: 0)
					encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: debug.count)
				}
			}
		}
		encoder.endEncoding()
		if let drawable: CAMetalDrawable = drawable { command.present(drawable) }
		command.commit()
		return command
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
		let command: MTLCommandBuffer = try self.draw(mesh, texture: texture)
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

	private func debugVertices(_ mesh: MeshGeometry.Snapshot, pixels: SIMD2<Float>) -> [DebugVertex] {
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
			for i in 0..<20 {
				let a: Float = Float(i) * .pi / 10
				let b: Float = Float(i + 1) * .pi / 10
				for v in [p, p + SIMD2<Float>(cos(a), sin(a)) * radius / pixels, p + SIMD2<Float>(cos(b), sin(b)) * radius / pixels] {
					vertices.append(DebugVertex(position: v, color: color))
				}
			}
		}
		let patches: [SIMD4<Float>] = MeshGeometry.patchData(mesh)
		let count: Int = patches.count / 32
		for patch in 0..<count {
			let net: [SIMD4<Float>] = Array(patches[(patch * 32)..<(patch * 32 + 16)])
			let tracks: [Float] = mesh.debugMode == .tessellation ? (0...8).map({ Float($0) / 8 }) : [0, 1]
			for track in tracks {
				for axis in 0..<2 {
					var previous: SIMD2<Float>?
					for step in 0...48 {
						let t: Float = Float(step) / 48
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
