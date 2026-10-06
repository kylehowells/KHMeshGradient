import Metal
import UIKit
import XCTest
@testable import KHMeshGradient

final class KHMeshGradientTests: XCTestCase {
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
}
