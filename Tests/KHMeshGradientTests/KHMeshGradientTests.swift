import Metal
import UIKit
import XCTest
@testable import KHMeshGradient

final class KHMeshGradientTests: XCTestCase {
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
		let pixel = self.rgba(try view.renderedImage(size: CGSize(width: 16, height: 16), usesPresentationValues: true), x: 8, y: 8)
		XCTAssertEqual(Int(pixel[0]), 191, accuracy: 3)
		XCTAssertEqual(Int(pixel[2]), 64, accuracy: 3)
		animator.stopAnimation(false)
		animator.finishAnimation(at: .start)
		self.pump(0.1)
		XCTAssertEqual(view.points[0], .zero)
		XCTAssertEqual(view.alpha, 1)
		XCTAssertEqual(view.colors[0].cgColor, UIColor.red.cgColor)
		let restored = self.rgba(try view.renderedImage(size: CGSize(width: 16, height: 16)), x: 8, y: 8)
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
		let pixel = self.rgba(try view.renderedImage(size: CGSize(width: 16, height: 16)), x: 0, y: 0)
		XCTAssertGreaterThan(pixel[1], 250)
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
		return Array(bytes[offset..<(offset + 4)])
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
		let pixel: [UInt8] = self.rgba(try view.renderedImage(size: CGSize(width: 32, height: 32)), x: 31, y: 31)
		XCTAssertGreaterThan(pixel[0], 250)
		XCTAssertLessThan(pixel[1], 5)
		XCTAssertGreaterThan(pixel[2], 250)
	}

	@MainActor func testInvalidSequentialConfigurationRecovers() throws {
		let view: KHMeshGradientView = try self.makeView()
		view.meshSize = .init(width: 3, height: 3)
		XCTAssertNotNil(view.configurationError)
		XCTAssertThrowsError(try view.renderedImage(size: CGSize(width: 16, height: 16)))
		view.points = (0..<9).map({ CGPoint(x: CGFloat($0 % 3) / 2, y: CGFloat($0 / 3) / 2) })
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
		let blue: [UInt8] = self.rgba(try view.renderedImage(size: CGSize(width: 8, height: 8)), x: 4, y: 4)
		XCTAssertGreaterThan(blue[2], 250)
		view.colors = Array(repeating: .red, count: 4)
		let red: [UInt8] = self.rgba(try view.renderedImage(size: CGSize(width: 8, height: 8)), x: 4, y: 4)
		XCTAssertGreaterThan(red[0], 250)
		view.bezierPoints = []
		XCTAssertNotNil(view.configurationError)
		let automaticPoints: [CGPoint] = view.points
		view.points = automaticPoints
		XCTAssertNil(view.configurationError)
	}

	func testAutomaticPatchBoundariesAndCornersAgree() {
		let points: [CGPoint] = (0..<9).map({ CGPoint(x: CGFloat($0 % 3) / 2, y: CGFloat($0 / 3) / 2) })
		let vertices = MeshGeometry.automaticVertices(points: points, size: .init(width: 3, height: 3))
		let left = MeshGeometry.positionNet(vertices[0], vertices[1], vertices[3], vertices[4])
		let right = MeshGeometry.positionNet(vertices[1], vertices[2], vertices[4], vertices[5])
		for step in 0...20 {
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
		view.points = (0..<9).map({ CGPoint(x: CGFloat($0 % 3) / 2, y: CGFloat($0 / 3) / 2) })
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
		let light: [UInt8] = self.rgba(try view.renderedImage(size: CGSize(width: 8, height: 8)), x: 4, y: 4)
		view.overrideUserInterfaceStyle = .dark
		self.pump(0.05)
		XCTAssertEqual(view.traitCollection.userInterfaceStyle, .dark)
		let dark: [UInt8] = self.rgba(try view.renderedImage(size: CGSize(width: 8, height: 8)), x: 4, y: 4)
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
			images.insert(try view.renderedImage(size: CGSize(width: 32, height: 32)).pngData()!)
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
