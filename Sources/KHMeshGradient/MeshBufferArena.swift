import Metal
import Foundation

// MARK: - MeshBufferPool

/// Buffer ownership lasts through command completion; a later frame never writes
/// into storage that the GPU is still reading. The shared cache has a byte limit.
final class MeshBufferPool: @unchecked Sendable {
	private let device: MTLDevice
	private let lock: NSLock = NSLock()
	private var available: [MTLBuffer] = []
	private var cachedBytes: Int = 0
	private let maximumCachedBytes: Int = 4 * 1024 * 1024

	init(device: MTLDevice) { self.device = device }

	func acquire(minimumSize: Int) throws -> MTLBuffer {
		self.lock.lock()
		if let index = self.available.indices.filter({ self.available[$0].length >= minimumSize }).min(by: { self.available[$0].length < self.available[$1].length }) {
			let buffer = self.available.remove(at: index)
			self.cachedBytes -= buffer.length
			self.lock.unlock()
			return buffer
		}
		self.lock.unlock()
		guard let buffer = self.device.makeBuffer(length: max(64 * 1024, minimumSize), options: .storageModeShared) else { throw MeshRenderer.Failure.resourceAllocation }

		buffer.label = "KHMeshGradient frame data"
		return buffer
	}

	func recycle(_ buffers: [MTLBuffer]) {
		self.lock.lock()
		defer { self.lock.unlock() }
		for buffer in buffers where self.cachedBytes + buffer.length <= self.maximumCachedBytes {
			self.available.append(buffer)
			self.cachedBytes += buffer.length
		}
	}
}

// MARK: - MeshBufferArena

/// One arena per command buffer, shared by all meshes encoded in that batch.
final class MeshBufferArena {
	private let pool: MeshBufferPool
	private(set) var buffers: [MTLBuffer] = []
	private var offset: Int = 0

	init(pool: MeshBufferPool) { self.pool = pool }

	func upload<T>(_ values: [T]) throws -> (buffer: MTLBuffer, offset: Int) {
		let length = values.count * MemoryLayout<T>.stride
		let alignedOffset = (self.offset + 255) & ~255
		if self.buffers.last == nil || alignedOffset + length > self.buffers.last!.length {
			try self.buffers.append(self.pool.acquire(minimumSize: length))
			self.offset = 0
		}
		else { self.offset = alignedOffset }
		let buffer = self.buffers.last!
		values.withUnsafeBytes({ bytes in
			buffer.contents().advanced(by: self.offset).copyMemory(from: bytes.baseAddress!, byteCount: length)
		})
		let result = (buffer, self.offset)
		self.offset += length
		return result
	}
}
