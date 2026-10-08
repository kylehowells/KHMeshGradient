import Metal
import UIKit
import XCTest
import simd
@testable import KHMeshGradient

final class KHMeshGradientTests: XCTestCase {
	@MainActor func testSingleCellEvaluatesCubicColorPerPixel() throws {
		let view = try self.makeView()
		view.colors = [.red, .green, .blue, .white]
		view.subdivisions = 1
		let mesh = try XCTUnwrap((view.layer as! KHMeshGradientLayer).snapshot())
		let controls = MeshGeometry.colorPatchData(mesh)
		let image = try view.renderedImage(size: CGSize(width: 64, height: 64))
		for (x, y) in [(7, 13), (19, 39), (43, 8), (55, 51)] {
			let expected = MeshGeometry.evaluate(controls, u: Float(x) / 64 + 0.5 / 64, v: Float(y) / 64 + 0.5 / 64)
			let pixel = self.rgba(image, x: x, y: y)
			for channel in 0 ..< 3 {
				XCTAssertEqual(Float(pixel[channel]), expected[channel] * 255, accuracy: 1)
			}
		}
		view.subdivisions = 128
		let dense = try view.renderedImage(size: CGSize(width: 64, height: 64))
		for (x, y) in [(7, 13), (19, 39), (43, 8), (55, 51)] {
			let low = self.rgba(image, x: x, y: y)
			let high = self.rgba(dense, x: x, y: y)
			for channel in 0 ..< 4 {
				XCTAssertEqual(Int(low[channel]), Int(high[channel]), accuracy: 1)
			}
		}
	}

	@MainActor func testFragmentColorsPreserveAlphaAndAllInterpolationSpacesAtOneCell() throws {
		let view = try self.makeView()
		view.colors = [.red.withAlphaComponent(0.2), .green.withAlphaComponent(0.7), .blue.withAlphaComponent(0.4), .white.withAlphaComponent(0.9)]
		for space in [KHMeshGradientView.ColorSpace.device, .linear, .perceptual] {
			view.colorSpace = space
			for smooth in [false, true] {
				view.smoothsColors = smooth
				view.subdivisions = 1
				let coarse = try view.renderedImage(size: CGSize(width: 48, height: 32))
				view.subdivisions = 128
				let fine = try view.renderedImage(size: CGSize(width: 48, height: 32))
				for (x, y) in [(5, 7), (18, 23), (35, 12)] {
					let a = self.rgba(coarse, x: x, y: y)
					let b = self.rgba(fine, x: x, y: y)
					for channel in 0 ..< 4 {
						XCTAssertEqual(Int(a[channel]), Int(b[channel]), accuracy: 1, "\(space), smooth=\(smooth)")
					}
				}
			}
		}
	}

	@MainActor func testAdaptiveDensityTracksPixelsAndCurvatureAndHonorsFixedOverride() throws {
		let view = try self.makeView()
		func density(_ pixels: SIMD2<Float>) throws -> Int {
			let mesh = try XCTUnwrap((view.layer as! KHMeshGradientLayer).snapshot())
			return MeshGeometry.subdivisionCount(mesh, patches: MeshGeometry.patchData(mesh), pixels: pixels)
		}
		XCTAssertEqual(view.subdivisions, 0)
		XCTAssertEqual(try density(SIMD2<Float>(304, 176)), 1)
		view.bezierPoints = view.resolvedBezierPoints
		view.bezierPoints![1].bottomControlPoint = CGPoint(x: 0.2, y: 0.25)
		view.bezierPoints![3].topControlPoint = CGPoint(x: 0.2, y: 0.75)
		let small = try density(SIMD2<Float>(152, 88))
		let large = try density(SIMD2<Float>(1216, 704))
		XCTAssertGreaterThan(small, 1)
		XCTAssertGreaterThan(large, small)
		view.maximumGeometryError = 0.05
		XCTAssertGreaterThan(try density(SIMD2<Float>(152, 88)), small)
		view.colors = [.black, .white, .red, .green]
		let unchanged = try density(SIMD2<Float>(152, 88))
		view.colors = [.green, .red, .white, .black]
		XCTAssertEqual(try density(SIMD2<Float>(152, 88)), unchanged)
		view.subdivisions = 7
		XCTAssertEqual(try density(SIMD2<Float>(1216, 704)), 7)
	}

	@MainActor func testFragmentPrecisionSelectionPreservesExtendedRangeColors() throws {
		let view = try self.makeView()
		func usesHalf() throws -> Bool {
			let mesh = try XCTUnwrap((view.layer as! KHMeshGradientLayer).snapshot())
			return MeshGeometry.fragmentColorCoefficients(mesh).usesHalf
		}
		#if arch(arm64)
			XCTAssertTrue(try usesHalf())
		#else
			XCTAssertFalse(try usesHalf())
		#endif
		view.colors[0] = .red.withAlphaComponent(0.3)
		XCTAssertFalse(try usesHalf())
		view.colors[0] = .red
		view.colorSpace = .perceptual
		XCTAssertFalse(try usesHalf())
		view.colorSpace = .device
		let color = try XCTUnwrap(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB)!, components: [1_000_000, 0, 0, 1]))
		view.resolvedColors = Array(repeating: color, count: 4)
		XCTAssertFalse(try usesHalf(), "Coefficients outside half's finite range use the float pipeline.")
		let pixel = try self.rgba(view.renderedImage(size: CGSize(width: 16, height: 16)), x: 8, y: 8)
		XCTAssertEqual(pixel, [255, 0, 0, 255])
	}

	@MainActor func testTessellationDebugShowsSelectedCellDiagonal() throws {
		let view = try self.makeView()
		view.colors = Array(repeating: .red, count: 4)
		view.subdivisions = 1
		view.debugMode = .tessellation
		let image = try view.renderedImage(size: CGSize(width: 64, height: 64))
		let diagonal = self.rgba(image, x: 31, y: 32)
		let interior = self.rgba(image, x: 16, y: 16)
		XCTAssertGreaterThan(diagonal[1], 200, "Show the actual diagonal between the two selected triangles.")
		XCTAssertLessThan(interior[1], 5, "A single-cell patch must not show the old fixed inspection grid.")
	}

	@MainActor func testAdaptiveDensityAccountsForMixedDerivativeAndBoundsWork() throws {
		let view = try self.makeView()
		// Bilinear geometry can have straight edges but a nonlinear parameter map.
		view.points[3] = CGPoint(x: 0.3, y: 0.6)
		let mesh = try XCTUnwrap((view.layer as! KHMeshGradientLayer).snapshot())
		XCTAssertGreaterThan(MeshGeometry.subdivisionCount(mesh, patches: MeshGeometry.patchData(mesh), pixels: SIMD2<Float>(720, 480)), 1)
		view.meshSize = .init(width: 64, height: 64)
		view.points = (0 ..< 4096).map({ index -> CGPoint in
			let x: CGFloat = CGFloat(index % 64) / 63
			let y: CGFloat = CGFloat(index / 64) / 63
			let offset: CGFloat = index % 2 == 0 ? 0.5 : 0
			return CGPoint(x: x, y: y + offset)
		})
		view.colors = Array(repeating: .red, count: 4096)
		let large = try XCTUnwrap((view.layer as! KHMeshGradientLayer).snapshot())
		let count = MeshGeometry.subdivisionCount(large, patches: MeshGeometry.patchData(large), pixels: SIMD2<Float>(16384, 16384))
		XCTAssertLessThanOrEqual(63 * 63 * count * count, 65_536)
	}

	@MainActor func testAdaptiveTrianglesRespectScreenSpaceGeometryTarget() throws {
		let view = try self.makeView()
		view.bezierPoints = view.resolvedBezierPoints
		view.bezierPoints![1].bottomControlPoint = CGPoint(x: 0.2, y: 0.25)
		view.bezierPoints![3].topControlPoint = CGPoint(x: 0.2, y: 0.75)
		let mesh = try XCTUnwrap((view.layer as! KHMeshGradientLayer).snapshot())
		let net = MeshGeometry.positionPatchData(mesh)
		let pixels = SIMD2<Float>(720, 480)
		let n = MeshGeometry.subdivisionCount(mesh, patches: net, pixels: pixels, positionStride: 16)
		XCTAssertLessThan(n, 128, "This fixture must exercise the error target without hitting the density cap.")
		for sample in 0 ..< 300 {
			let u: Float = Float((sample * 37) % 997) / 997
			let v: Float = Float((sample * 61) % 991) / 991
			let x = floor(u * Float(n))
			let y = floor(v * Float(n))
			let a = MeshGeometry.evaluate(net, u: x / Float(n), v: y / Float(n))
			let b = MeshGeometry.evaluate(net, u: (x + 1) / Float(n), v: y / Float(n))
			let c = MeshGeometry.evaluate(net, u: x / Float(n), v: (y + 1) / Float(n))
			let d = MeshGeometry.evaluate(net, u: (x + 1) / Float(n), v: (y + 1) / Float(n))
			let fu = u * Float(n) - x
			let fv = v * Float(n) - y
			let linear = fu + fv <= 1 ? a * (1 - fu - fv) + b * fu + c * fv : b * (1 - fv) + d * (fu + fv - 1) + c * (1 - fu)
			let exact = MeshGeometry.evaluate(net, u: u, v: v)
			let difference = SIMD2<Float>(linear.x - exact.x, linear.y - exact.y) * pixels
			XCTAssertLessThanOrEqual(simd_length(difference), mesh.maximumGeometryError)
		}
	}

	@MainActor func testAdaptiveDensityFollowsPresentationGeometryAndStopsAtIdle() throws {
		let view = try self.makeView()
		view.collectsRenderingStatistics = true
		let window = self.attach(view)
		defer { window.isHidden = true }
		self.pump(0.1)
		XCTAssertEqual(view.renderingStatistics.lastSubdivisionCount, 1)
		view.bezierPoints = view.resolvedBezierPoints
		let animator = UIViewPropertyAnimator(duration: 1, curve: .linear, animations: {
			view.bezierPoints![1].bottomControlPoint = CGPoint(x: 0.2, y: 0.25)
			view.bezierPoints![3].topControlPoint = CGPoint(x: 0.2, y: 0.75)
		})
		animator.startAnimation()
		animator.pauseAnimation()
		animator.fractionComplete = 0.7
		self.pump(0.1)
		XCTAssertGreaterThan(view.renderingStatistics.lastSubdivisionCount, 1)
		XCTAssertGreaterThan(view.renderingStatistics.triangleCount, 0)
		let count = view.renderedFrameCount
		self.pump(0.15)
		XCTAssertEqual(view.renderedFrameCount, count)
		view.subdivisions = 7
		self.pump(0.1)
		XCTAssertEqual(view.renderingStatistics.lastSubdivisionCount, 7, "Policy changes apply even while the animator is paused.")
		view.subdivisions = 0
		animator.fractionComplete = 0
		self.pump(0.1)
		XCTAssertEqual(view.renderingStatistics.lastSubdivisionCount, 1)
		animator.stopAnimation(true)
	}

	@MainActor func testPropertyAnimatorScrubsPausesResumesAndFinishes() throws {
		let view: KHMeshGradientView = try self.makeView()
		let window: UIWindow = self.attach(view)
		defer { window.isHidden = true }
		self.pump(0.15)
		let animator: UIViewPropertyAnimator = UIViewPropertyAnimator(duration: 0.6, curve: .linear, animations: {
			view.points[0] = CGPoint(x: 0.8, y: 0.6)
			view.points[1] = CGPoint(x: 0.7, y: 0.1)
			view.colors[0] = .blue
		})
		animator.startAnimation()
		self.pump(0.1)
		animator.pauseAnimation()
		animator.fractionComplete = 0.25
		self.pump(0.1)
		XCTAssertEqual(view.presentationPoints[0].x, 0.2, accuracy: 0.01)
		XCTAssertEqual(view.presentationPoints[1].x, 0.925, accuracy: 0.01)
		let count: UInt64 = view.renderedFrameCount
		self.pump(0.8)
		XCTAssertEqual(view.renderedFrameCount, count, "Paused mesh must not submit frames.")
		animator.fractionComplete = 0.75
		self.pump(0.1)
		XCTAssertEqual(view.presentationPoints[0].x, 0.6, accuracy: 0.01)
		XCTAssertGreaterThan(view.renderedFrameCount, count, "Scrubbing must redraw Metal.")
		let beforeResume: UInt64 = view.renderedFrameCount
		let completion = self.expectation(description: "Animator finishes")
		animator.addCompletion({ position in
			XCTAssertEqual(position, .end)
			completion.fulfill()
		})
		animator.continueAnimation(withTimingParameters: nil, durationFactor: 1)
		self.wait(for: [completion], timeout: 3)
		XCTAssertGreaterThan(view.renderedFrameCount, beforeResume, "Resume after the original duration must still redraw.")
		XCTAssertEqual(view.presentationPoints[0].x, 0.8, accuracy: 0.01)
		self.pump(0.1)
		let settled: UInt64 = view.renderedFrameCount
		self.pump(0.2)
		XCTAssertEqual(view.renderedFrameCount, settled)
	}

	@MainActor func testPropertyAnimatorFinishStartRestoresModelAndMetalPixels() throws {
		let view = try self.makeView()
		view.colors = Array(repeating: .red, count: 4)
		let window = self.attach(view)
		defer { window.isHidden = true }
		self.pump(0.1)
		let animator = UIViewPropertyAnimator(duration: 1, curve: .linear, animations: {
			view.colors = Array(repeating: .blue, count: 4)
			view.points[0] = CGPoint(x: 0.2, y: 0.2)
			view.alpha = 0.5
		})
		animator.startAnimation()
		animator.pauseAnimation()
		animator.fractionComplete = 0.25
		self.pump(0.1)
		let pixel = try self.rgba(view.renderedImage(size: CGSize(width: 16, height: 16), usesPresentationValues: true), x: 8, y: 8)
		XCTAssertEqual(Int(pixel[0]), 191, accuracy: 3)
		XCTAssertEqual(Int(pixel[2]), 64, accuracy: 3)
		animator.stopAnimation(false)
		animator.finishAnimation(at: .start)
		self.pump(0.1)
		XCTAssertEqual(view.points[0], .zero)
		XCTAssertEqual(view.alpha, 1)
		XCTAssertEqual(view.colors[0].cgColor, UIColor.red.cgColor)
		let restored = try self.rgba(view.renderedImage(size: CGSize(width: 16, height: 16)), x: 8, y: 8)
		XCTAssertGreaterThan(restored[0], 250)
		XCTAssertLessThan(restored[2], 5)
		// A subsequent unrelated setter must not put the cancelled target back.
		view.debugMode = .mesh
		XCTAssertEqual(view.resolvedBezierPoints[0].position, .zero)
	}

	@MainActor func testOverlappingPropertyAnimatorsAndLegacyAnimationRedraw() throws {
		let view = try self.makeView()
		let window = self.attach(view)
		defer { window.isHidden = true }
		self.pump(0.1)
		let long = UIViewPropertyAnimator(duration: 1, curve: .linear, animations: { view.points[0].x = 0.5 })
		let short = UIViewPropertyAnimator(duration: 0.2, curve: .linear, animations: { view.colors[3] = .black })
		long.startAnimation()
		short.startAnimation()
		self.pump(0.4)
		let count = view.renderedFrameCount
		self.pump(0.2)
		XCTAssertGreaterThan(view.renderedFrameCount, count, "Short animator must not stop the longer redraw driver.")
		long.pauseAnimation()
		long.fractionComplete = 0.7
		self.pump(0.1)
		long.isReversed = true
		let completion = self.expectation(description: "Reverse completes")
		long.addCompletion({ position in XCTAssertEqual(position, .start); completion.fulfill() })
		long.continueAnimation(withTimingParameters: UICubicTimingParameters(animationCurve: .easeInOut), durationFactor: 0.2)
		self.wait(for: [completion], timeout: 3)
		XCTAssertEqual(view.points[0].x, 0, accuracy: 0.01)
		self.pump(0.1)
		let legacyStart = view.renderedFrameCount
		UIView.animate(withDuration: 0.3, animations: { view.points[0].x = 0.4 })
		self.pump(0.15)
		XCTAssertGreaterThan(view.renderedFrameCount, legacyStart + 1)
		XCTAssertGreaterThan(view.presentationPoints[0].x, 0)
		XCTAssertLessThan(view.presentationPoints[0].x, 0.4)
		self.pump(0.4)
		let settled = view.renderedFrameCount
		self.pump(0.2)
		XCTAssertEqual(view.renderedFrameCount, settled)
	}

	@MainActor func testPropertyAnimatorSpringHandlesAndFinishCurrent() throws {
		let view = try self.makeView()
		view.bezierPoints = view.resolvedBezierPoints
		view.meshBackgroundColor = .red
		let window = self.attach(view)
		defer { window.isHidden = true }
		self.pump(0.1)
		let start = view.bezierPoints![0].trailingControlPoint
		let animator = UIViewPropertyAnimator(duration: 0.7, dampingRatio: 0.8, animations: {
			view.bezierPoints![0].trailingControlPoint = CGPoint(x: 0.6, y: 0.3)
			view.meshBackgroundColor = .blue
		})
		animator.startAnimation()
		self.pump(0.1)
		animator.pauseAnimation()
		animator.fractionComplete = 0.5
		self.pump(0.1)
		let displayed = (view.layer.presentation() as? KHMeshGradientLayer)?.snapshot()?.vertices[0].trailingControlPoint
		XCTAssertNotNil(displayed)
		XCTAssertNotEqual(displayed, start)
		animator.stopAnimation(false)
		animator.finishAnimation(at: .current)
		self.pump(0.1)
		XCTAssertEqual(view.bezierPoints![0].trailingControlPoint.x, displayed!.x, accuracy: 0.01)
		XCTAssertEqual(view.resolvedBezierPoints[0].trailingControlPoint.x, displayed!.x, accuracy: 0.01)
		let settled = view.renderedFrameCount
		self.pump(0.2)
		XCTAssertEqual(view.renderedFrameCount, settled)
	}

	@MainActor func testPropertyAnimatorRestoresDynamicColorsAndAddsAnimations() throws {
		let view = try self.makeView()
		let original = UIColor { traits in traits.userInterfaceStyle == .dark ? .green : .red }
		view.colors = Array(repeating: original, count: 4)
		let window = self.attach(view)
		defer { window.isHidden = true }
		self.pump(0.1)
		let animator = UIViewPropertyAnimator(duration: 1, curve: .linear, animations: { view.colors[0] = .blue })
		animator.startAnimation()
		animator.pauseAnimation()
		animator.addAnimations({ view.points[1].y = 0.4 })
		animator.fractionComplete = 0.5
		self.pump(0.1)
		XCTAssertGreaterThan(view.presentationPoints[1].y, 0)
		animator.stopAnimation(false)
		animator.finishAnimation(at: .start)
		self.pump(0.1)
		XCTAssertEqual(view.points[1].y, 0, accuracy: 0.01)
		XCTAssertEqual(view.colors[0].resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).cgColor, UIColor.green.cgColor)
		view.overrideUserInterfaceStyle = .dark
		self.pump(0.1)
		let pixel = try self.rgba(view.renderedImage(size: CGSize(width: 16, height: 16)), x: 0, y: 0)
		XCTAssertGreaterThan(pixel[1], 250)
	}

	@MainActor func testDistinctViewsBatchTogetherAndStopAtIdle() throws {
		let container = UIView(frame: CGRect(x: 0, y: 0, width: 256, height: 256))
		let views = try (0 ..< 4).map({ index -> KHMeshGradientView in
			let view = try self.makeView()
			view.frame.origin = CGPoint(x: (index % 2) * 128, y: (index / 2) * 128)
			container.addSubview(view)
			return view
		})
		let window = self.attach(container)
		defer { window.isHidden = true }
		self.pump(0.2)
		let renderer = try MeshRenderer.shared.get()
		let before = renderer.submittedBatchCount
		let counts = views.map({ $0.renderedFrameCount })
		for (index, view) in views.enumerated() {
			view.resetRenderingStatistics()
			view.collectsRenderingStatistics = true
			view.colors = Array(repeating: UIColor(hue: CGFloat(index) / 4, saturation: 1, brightness: 1, alpha: 1), count: 4)
		}
		CATransaction.flush()
		renderer.flush()
		XCTAssertEqual(renderer.submittedBatchCount, before + 1)
		self.pump(0.15)
		for (index, view) in views.enumerated() {
			XCTAssertEqual(view.renderedFrameCount, counts[index] + 1)
			XCTAssertEqual(view.renderingStatistics.commandBufferCount, 0.25, accuracy: 0.0001)
			XCTAssertEqual(view.renderingStatistics.renderPassCount, 0.25, accuracy: 0.0001)
			XCTAssertEqual(view.renderingStatistics.gpuErrorCount, 0)
		}
		let settled = renderer.submittedBatchCount
		self.pump(0.2)
		XCTAssertEqual(renderer.submittedBatchCount, settled)
	}

	@MainActor func testBatchPixelsMatchIndependentRendersAndDoNotBleed() throws {
		let renderer = try MeshRenderer.shared.get()
		let views = try (0 ..< 9).map({ index -> KHMeshGradientView in
			let view = try self.makeView()
			view.points[3] = CGPoint(x: 0.6, y: 0.7)
			view.meshBackgroundColor = UIColor(hue: CGFloat(index) / 9, saturation: 1, brightness: 1, alpha: 0.6)
			view.colors[0] = UIColor.red.withAlphaComponent(0.5)
			view.colors[1] = UIColor(hue: CGFloat(index) / 9, saturation: 1, brightness: 0.8, alpha: 1)
			if index == 1 { view.colorSpace = .perceptual }
			if index == 2 || index == 7 { view.debugMode = .controlPoints }
			return view
		})
		var sizes = [CGSize](repeating: CGSize(width: 32, height: 24), count: 9)
		sizes[8] = CGSize(width: 53, height: 41)
		func texture(_ size: CGSize) throws -> MTLTexture {
			let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
			descriptor.storageMode = .shared
			descriptor.usage = .renderTarget
			return try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
		}
		func pixels(_ texture: MTLTexture) -> [UInt8] {
			var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
			texture.getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
			return bytes
		}
		let meshes = views.map({ ($0.layer as! KHMeshGradientLayer).snapshot() })
		let targets = try sizes.map(texture)
		let batch = try renderer.render(meshes, into: targets)
		batch.waitUntilCompleted()
		XCTAssertNil(batch.error)
		for index in views.indices {
			let reference = try texture(sizes[index])
			let command = try renderer.render([meshes[index]], into: [reference])
			command.waitUntilCompleted()
			XCTAssertNil(command.error)
			let maximumDifference = zip(pixels(targets[index]), pixels(reference)).map({ abs(Int($0.0) - Int($0.1)) }).max()!
			XCTAssertEqual(maximumDifference, 0, "Batches must preserve distinct colors, outside background, transparency, and debug overlays.")
		}
	}

	@MainActor func testMultipleAnimatedViewsCoalesceAndScrubTogether() throws {
		let container = UIView(frame: CGRect(x: 0, y: 0, width: 256, height: 256))
		let views = try (0 ..< 4).map({ index -> KHMeshGradientView in
			let view = try self.makeView()
			view.frame.origin = CGPoint(x: (index % 2) * 128, y: (index / 2) * 128)
			container.addSubview(view)
			return view
		})
		let window = self.attach(container)
		defer { window.isHidden = true }
		self.pump(0.2)
		for view in views {
			view.resetRenderingStatistics(); view.collectsRenderingStatistics = true
		}
		let animator = UIViewPropertyAnimator(duration: 1, curve: .linear, animations: {
			for view in views {
				view.points[0] = CGPoint(x: 0.4, y: 0.2)
			}
		})
		animator.startAnimation()
		self.pump(0.2)
		animator.pauseAnimation()
		self.pump(0.1)
		let statistics = views.map({ $0.renderingStatistics })
		let buffers = statistics.reduce(0, { $0 + $1.commandBufferCount })
		let maximumDrawCount = statistics.map({ $0.cpuFrameCount }).max()!
		XCTAssertGreaterThan(maximumDrawCount, 2)
		XCTAssertLessThanOrEqual(buffers, Double(maximumDrawCount) + 2, "Animated views must share submissions too.")
		let renderer = try MeshRenderer.shared.get()
		let before = renderer.submittedBatchCount
		animator.fractionComplete = 0.75
		self.pump(0.1)
		for view in views {
			XCTAssertEqual(view.presentationPoints[0].x, 0.3, accuracy: 0.01)
		}
		XCTAssertEqual(renderer.submittedBatchCount, before + 1)
		let paused = renderer.submittedBatchCount
		self.pump(0.2)
		XCTAssertEqual(renderer.submittedBatchCount, paused)
		animator.stopAnimation(false)
		animator.finishAnimation(at: .current)
	}

	@MainActor private func makeView() throws -> KHMeshGradientView {
		guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable.") }

		let view: KHMeshGradientView = KHMeshGradientView(frame: CGRect(x: 0, y: 0, width: 128, height: 128))
		view.colors = [.red, .green, .blue, .white]
		if let error: Error = view.renderingError { XCTFail("Renderer initialization failed: \(error)") }
		return view
	}

	@MainActor private func pump(_ seconds: TimeInterval) {
		let expectation: XCTestExpectation = self.expectation(description: "Run loop advances")
		DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: { expectation.fulfill() })
		self.wait(for: [expectation], timeout: seconds + 5)
	}

	@MainActor private func attach(_ view: UIView) -> UIWindow {
		let window: UIWindow = UIWindow(frame: UIScreen.main.bounds)
		let root: UIViewController = UIViewController()
		window.rootViewController = root
		window.makeKeyAndVisible()
		root.view.addSubview(view)
		view.setNeedsLayout()
		view.layoutIfNeeded()
		return window
	}

	private func rgba(_ image: UIImage, x: Int, y: Int) -> [UInt8] {
		let cgImage: CGImage = image.cgImage!
		var bytes: [UInt8] = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
		let context: CGContext = CGContext(data: &bytes, width: cgImage.width, height: cgImage.height,
		                                   bitsPerComponent: 8, bytesPerRow: cgImage.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
		                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
		context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
		let offset: Int = (y * cgImage.width + x) * 4
		return Array(bytes[offset ..< (offset + 4)])
	}

	@MainActor func testMetalRenderingPreservesCornerColors() throws {
		let view: KHMeshGradientView = try self.makeView()
		let image: UIImage = try view.renderedImage(size: CGSize(width: 64, height: 64), scale: 2)
		XCTAssertEqual(image.cgImage?.width, 128)
		let a: [UInt8] = self.rgba(image, x: 0, y: 0)
		let b: [UInt8] = self.rgba(image, x: 127, y: 0)
		let c: [UInt8] = self.rgba(image, x: 0, y: 127)
		XCTAssertGreaterThan(a[0], 250)
		XCTAssertLessThan(a[1], 5)
		XCTAssertGreaterThan(b[1], 250)
		XCTAssertGreaterThan(c[2], 250)
	}

	@MainActor func testTransparencyDoesNotRevealMeshBackgroundInsidePatch() throws {
		let view: KHMeshGradientView = try self.makeView()
		view.colors = Array(repeating: UIColor.red.withAlphaComponent(0.5), count: 4)
		view.meshBackgroundColor = .blue
		let image: UIImage = try view.renderedImage(size: CGSize(width: 32, height: 32))
		let pixel: [UInt8] = self.rgba(image, x: 16, y: 16)
		XCTAssertEqual(Int(pixel[0]), 128, accuracy: 2)
		XCTAssertEqual(Int(pixel[2]), 0, accuracy: 1)
		XCTAssertEqual(Int(pixel[3]), 128, accuracy: 2)
	}

	@MainActor func testBackgroundFillsOutsideInsetMesh() throws {
		let view: KHMeshGradientView = try self.makeView()
		view.points[3] = CGPoint(x: 0.6, y: 0.6)
		view.meshBackgroundColor = .magenta
		let pixel: [UInt8] = try self.rgba(view.renderedImage(size: CGSize(width: 32, height: 32)), x: 31, y: 31)
		XCTAssertGreaterThan(pixel[0], 250)
		XCTAssertLessThan(pixel[1], 5)
		XCTAssertGreaterThan(pixel[2], 250)
	}

	@MainActor func testInvalidSequentialConfigurationRecovers() throws {
		let view: KHMeshGradientView = try self.makeView()
		view.meshSize = .init(width: 3, height: 3)
		XCTAssertNotNil(view.configurationError)
		XCTAssertThrowsError(try view.renderedImage(size: CGSize(width: 16, height: 16)))
		view.points = (0 ..< 9).map({ CGPoint(x: CGFloat($0 % 3) / 2, y: CGFloat($0 / 3) / 2) })
		view.colors = Array(repeating: .red, count: 9)
		XCTAssertNil(view.configurationError)
		XCTAssertNoThrow(try view.renderedImage(size: CGSize(width: 16, height: 16)))
		view.points[4].x = .nan
		XCTAssertNotNil(view.configurationError)
		view.meshSize = .init(width: Int.max, height: Int.max)
		XCTAssertNotNil(view.configurationError)
	}

	@MainActor func testColorAndGeometrySourceSwitching() throws {
		let view: KHMeshGradientView = try self.makeView()
		view.resolvedColors = Array(repeating: UIColor.blue.cgColor, count: 4)
		let blue: [UInt8] = try self.rgba(view.renderedImage(size: CGSize(width: 8, height: 8)), x: 4, y: 4)
		XCTAssertGreaterThan(blue[2], 250)
		view.colors = Array(repeating: .red, count: 4)
		let red: [UInt8] = try self.rgba(view.renderedImage(size: CGSize(width: 8, height: 8)), x: 4, y: 4)
		XCTAssertGreaterThan(red[0], 250)
		view.bezierPoints = []
		XCTAssertNotNil(view.configurationError)
		let automaticPoints: [CGPoint] = view.points
		view.points = automaticPoints
		XCTAssertNil(view.configurationError)
	}

	func testAutomaticPatchBoundariesAndCornersAgree() {
		let points: [CGPoint] = (0 ..< 9).map({ CGPoint(x: CGFloat($0 % 3) / 2, y: CGFloat($0 / 3) / 2) })
		let vertices = MeshGeometry.automaticVertices(points: points, size: .init(width: 3, height: 3))
		let left = MeshGeometry.positionNet(vertices[0], vertices[1], vertices[3], vertices[4])
		let right = MeshGeometry.positionNet(vertices[1], vertices[2], vertices[4], vertices[5])
		for step in 0 ... 20 {
			let v: Float = Float(step) / 20
			let a = MeshGeometry.evaluate(left, u: 1, v: v)
			let b = MeshGeometry.evaluate(right, u: 0, v: v)
			XCTAssertEqual(a.x, b.x, accuracy: 0.00001)
			XCTAssertEqual(a.y, b.y, accuracy: 0.00001)
		}
		XCTAssertEqual(MeshGeometry.evaluate(left, u: 0, v: 0).x, 0, accuracy: 0.00001)
		XCTAssertEqual(MeshGeometry.evaluate(left, u: 1, v: 1).y, 0.5, accuracy: 0.00001)
	}

	@MainActor func testDebugModesRenderAndImageSizeValidation() throws {
		let view: KHMeshGradientView = try self.makeView()
		let clean: Data = try view.renderedImage(size: CGSize(width: 64, height: 64)).pngData()!
		for mode in [KHMeshGradientView.DebugMode.mesh, .controlPoints, .tessellation] {
			view.debugMode = mode
			let debug: Data = try view.renderedImage(size: CGSize(width: 64, height: 64)).pngData()!
			XCTAssertNotEqual(clean, debug)
		}
		XCTAssertThrowsError(try view.renderedImage(size: .zero))
		XCTAssertThrowsError(try view.renderedImage(size: CGSize(width: 8, height: 8), scale: .infinity))
	}

	@MainActor func testUIViewPointAnimationInterpolatesAndStopsDrawing() throws {
		let view: KHMeshGradientView = try self.makeView()
		view.meshSize = .init(width: 3, height: 3)
		view.points = (0 ..< 9).map({ CGPoint(x: CGFloat($0 % 3) / 2, y: CGFloat($0 / 3) / 2) })
		view.colors = Array(repeating: .red, count: 9)
		let window: UIWindow = self.attach(view)
		defer { window.isHidden = true }
		self.pump(0.2)
		let startCount: UInt64 = view.renderedFrameCount
		XCTAssertGreaterThan(startCount, 0)
		UIView.animate(withDuration: 0.6, delay: 0, options: [.curveLinear, .beginFromCurrentState], animations: {
			view.points[4] = CGPoint(x: 0.8, y: 0.3)
		}, completion: nil)
		self.pump(0.2)
		XCTAssertNotNil(view.layer.animation(forKey: "mesh_point_4"))
		let mid: CGPoint = view.presentationPoints[4]
		XCTAssertGreaterThan(mid.x, 0.5)
		XCTAssertLessThan(mid.x, 0.8)
		XCTAssertGreaterThan(view.renderedFrameCount, startCount + 1)
		self.pump(0.65)
		XCTAssertEqual(view.presentationPoints[4].x, 0.8, accuracy: 0.001)
		let finalCount: UInt64 = view.renderedFrameCount
		self.pump(0.3)
		XCTAssertEqual(view.renderedFrameCount, finalCount, "A static mesh must not submit more GPU frames.")
	}

	@MainActor func testInterruptedColorAnimationAndSuspension() throws {
		let view: KHMeshGradientView = try self.makeView()
		view.colors = Array(repeating: .red, count: 4)
		let window: UIWindow = self.attach(view)
		defer { window.isHidden = true }
		self.pump(0.1)
		UIView.animate(withDuration: 0.6, animations: { view.colors = Array(repeating: .blue, count: 4) })
		self.pump(0.2)
		let source: CALayer = view.layer.presentation() ?? view.layer
		let current = MeshGeometry.rgba(source.value(forKey: "mesh_color_0") as! CGColor)
		XCTAssertGreaterThan(current.x, 0)
		XCTAssertGreaterThan(current.z, 0)
		UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState], animations: {
			view.colors = Array(repeating: .green, count: 4)
		}, completion: nil)
		let animation: CABasicAnimation = try XCTUnwrap(view.layer.animation(forKey: "mesh_color_0") as? CABasicAnimation)
		let from = MeshGeometry.rgba(animation.fromValue as! CGColor)
		XCTAssertEqual(from.x, current.x, accuracy: 0.05)
		self.pump(0.45)
		view.isRenderingSuspended = true
		let count: UInt64 = view.renderedFrameCount
		view.colors = Array(repeating: .yellow, count: 4)
		self.pump(0.15)
		XCTAssertEqual(view.renderedFrameCount, count)
		view.isRenderingSuspended = false
		self.pump(0.15)
		XCTAssertGreaterThan(view.renderedFrameCount, count)
	}

	@MainActor func testSpringAnimationCreatesCustomActions() throws {
		let view: KHMeshGradientView = try self.makeView()
		let window: UIWindow = self.attach(view)
		defer { window.isHidden = true }
		self.pump(0.1)
		UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0,
		               options: [], animations: { view.points[0] = CGPoint(x: -0.2, y: -0.2) }, completion: nil)
		XCTAssertNotNil(view.layer.animation(forKey: "mesh_point_0"))
		let animation: CASpringAnimation = try XCTUnwrap(view.layer.animation(forKey: "mesh_point_0") as? CASpringAnimation)
		XCTAssertGreaterThan(animation.stiffness, 0)
		let count: UInt64 = view.renderedFrameCount
		self.pump(0.15)
		XCTAssertGreaterThan(view.renderedFrameCount, count)
		self.pump(0.65)
		XCTAssertEqual(view.presentationPoints[0].x, -0.2, accuracy: 0.001)
	}

	@MainActor func testImmediateChangeCancelsPreviousAnimation() throws {
		let view: KHMeshGradientView = try self.makeView()
		let window: UIWindow = self.attach(view)
		defer { window.isHidden = true }
		self.pump(0.1)
		UIView.animate(withDuration: 1, animations: { view.points[0] = CGPoint(x: -0.2, y: 0) })
		self.pump(0.15)
		UIView.performWithoutAnimation({ view.points[0] = CGPoint(x: -0.4, y: 0) })
		self.pump(0.05)
		XCTAssertNil(view.layer.animation(forKey: "mesh_point_0"))
		XCTAssertEqual(view.presentationPoints[0].x, -0.4, accuracy: 0.001)
	}

	@MainActor func testDynamicColorsResolveAgainstViewTraits() throws {
		let view: KHMeshGradientView = try self.makeView()
		let window: UIWindow = self.attach(view)
		defer { window.isHidden = true }
		let color: UIColor = UIColor(dynamicProvider: { traits in traits.userInterfaceStyle == .dark ? .white : .black })
		view.overrideUserInterfaceStyle = .light
		self.pump(0.05)
		view.colors = Array(repeating: color, count: 4)
		let light: [UInt8] = try self.rgba(view.renderedImage(size: CGSize(width: 8, height: 8)), x: 4, y: 4)
		view.overrideUserInterfaceStyle = .dark
		self.pump(0.05)
		XCTAssertEqual(view.traitCollection.userInterfaceStyle, .dark)
		let dark: [UInt8] = try self.rgba(view.renderedImage(size: CGSize(width: 8, height: 8)), x: 4, y: 4)
		XCTAssertLessThan(light[0], 5)
		XCTAssertGreaterThan(dark[0], 250)
	}

	@MainActor func testExplicitHandlesAnimateAndCompletionRuns() throws {
		let view: KHMeshGradientView = try self.makeView()
		view.bezierPoints = view.resolvedBezierPoints
		let window: UIWindow = self.attach(view)
		defer { window.isHidden = true }
		self.pump(0.1)
		let completion: XCTestExpectation = self.expectation(description: "UIKit animation completion")
		UIView.animate(withDuration: 0.3, animations: {
			view.bezierPoints![0].trailingControlPoint.y = 0.3
		}, completion: { finished in
			XCTAssertTrue(finished)
			completion.fulfill()
		})
		self.wait(for: [completion], timeout: 3)
		XCTAssertEqual(view.resolvedBezierPoints[0].trailingControlPoint.y, 0.3, accuracy: 0.001)
	}

	@MainActor func testAllInterpolationSpacesRender() throws {
		let view: KHMeshGradientView = try self.makeView()
		var images: Set<Data> = []
		for space in [KHMeshGradientView.ColorSpace.device, .perceptual, .linear] {
			view.colorSpace = space
			try images.insert(view.renderedImage(size: CGSize(width: 32, height: 32)).pngData()!)
		}
		XCTAssertEqual(images.count, 3)
	}

	@MainActor func testOptInRenderingStatisticsAndReset() throws {
		let view: KHMeshGradientView = try self.makeView()
		let window: UIWindow = self.attach(view)
		defer { window.isHidden = true }
		self.pump(0.15)
		XCTAssertEqual(view.renderingStatistics.cpuFrameCount, 0)
		view.collectsRenderingStatistics = true
		view.resetRenderingStatistics()
		view.points[0] = CGPoint(x: -0.1, y: -0.1)
		self.pump(0.15)
		let measured: KHMeshGradientView.RenderingStatistics = view.renderingStatistics
		XCTAssertGreaterThan(measured.cpuFrameCount, 0)
		XCTAssertGreaterThan(measured.cpuFrameSeconds, 0)
		XCTAssertGreaterThan(measured.encodingSeconds, 0)
		XCTAssertEqual(measured.gpuErrorCount, 0)
		view.collectsRenderingStatistics = false
		view.points[0] = CGPoint(x: -0.2, y: -0.1)
		self.pump(0.15)
		XCTAssertEqual(view.renderingStatistics.cpuFrameCount, measured.cpuFrameCount)
		view.resetRenderingStatistics()
		XCTAssertEqual(view.renderingStatistics.cpuFrameCount, 0)
		XCTAssertEqual(view.renderingStatistics.gpuFrameCount, 0)
	}
}
