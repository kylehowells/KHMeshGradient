import Foundation
import Metal

extension KHMeshGradientView {
	/// Opt-in diagnostics for this view's onscreen Metal rendering. CPU times are
	/// elapsed wall times (including waits), not process CPU consumption. GPU times
	/// are equal shares of completed batch command-buffer envelopes, excluding the
	/// compositor. They are allocations across views, not isolated per-view timings.
	public struct RenderingStatistics: Codable, Sendable {
		/// Fractional command-buffer contribution: sum across views for the batch count.
		public internal(set) var commandBufferCount: Double = 0
		/// Fractional render-pass contribution: sum across views for the pass count.
		public internal(set) var renderPassCount: Double = 0
		public internal(set) var cpuFrameCount: UInt64 = 0
		public internal(set) var cpuFrameSeconds: Double = 0
		public internal(set) var snapshotSeconds: Double = 0
		public internal(set) var drawableWaitSeconds: Double = 0
		public internal(set) var encodingSeconds: Double = 0
		public internal(set) var schedulingWaitSeconds: Double = 0
		public internal(set) var gpuFrameCount: UInt64 = 0
		/// Sum of this view's equal shares of completed batch GPU envelopes.
		public internal(set) var gpuFrameSeconds: Double = 0
		public internal(set) var gpuFrameMaximumSeconds: Double = 0
		public internal(set) var gpuErrorCount: UInt64 = 0
		public internal(set) var presentedFrameCount: UInt64 = 0
		public internal(set) var presentationIntervalCount: UInt64 = 0
		public internal(set) var presentationIntervalSeconds: Double = 0
		public init() { }
	}
}

/// GPU completion and drawable presentation callbacks can run off the main thread.
/// Only aggregate counters are retained; no unbounded sample buffers or allocations
/// are made for each frame. Replacing a store isolates in-flight frames on reset.
final class MeshRenderingStatisticsStore: @unchecked Sendable {
	private let lock: NSLock = NSLock()
	private var value: KHMeshGradientView.RenderingStatistics = .init()
	private var previousPresentationTime: Double = 0

	func snapshot() -> KHMeshGradientView.RenderingStatistics {
		self.lock.lock()
		defer { self.lock.unlock() }
		return self.value
	}

	func recordCPU(total: Double, snapshot: Double, drawable: Double, encoding: Double, scheduling: Double, commandBuffers: Double = 1, renderPasses: Double = 1) {
		self.lock.lock()
		defer { self.lock.unlock() }
		self.value.commandBufferCount += commandBuffers
		self.value.renderPassCount += renderPasses
		self.value.cpuFrameCount += 1
		self.value.cpuFrameSeconds += total
		self.value.snapshotSeconds += snapshot
		self.value.drawableWaitSeconds += drawable
		self.value.encodingSeconds += encoding
		self.value.schedulingWaitSeconds += scheduling
	}

	func recordGPU(_ command: MTLCommandBuffer, share: Double = 1) {
		self.lock.lock()
		defer { self.lock.unlock() }
		if command.error != nil { self.value.gpuErrorCount += 1 }
		let start: Double = command.gpuStartTime
		let end: Double = command.gpuEndTime
		guard start > 0, end >= start else { return }
		let duration: Double = (end - start) * share
		self.value.gpuFrameCount += 1
		self.value.gpuFrameSeconds += duration
		self.value.gpuFrameMaximumSeconds = max(self.value.gpuFrameMaximumSeconds, duration)
	}

	func recordPresentation(_ drawable: MTLDrawable) {
		#if !targetEnvironment(simulator)
		let time: Double = drawable.presentedTime
		guard time > 0 else { return }
		self.lock.lock()
		defer { self.lock.unlock() }
		self.value.presentedFrameCount += 1
		if self.previousPresentationTime > 0, time > self.previousPresentationTime {
			self.value.presentationIntervalCount += 1
			self.value.presentationIntervalSeconds += time - self.previousPresentationTime
		}
		self.previousPresentationTime = time
		#endif
	}
}
