import KHMeshGradient
import SwiftUI
import UIKit

// MARK: - GeometryExperiment

/// Diagnostic fixtures and exports stay in the example, outside the library.
enum GeometryExperiment {
	static let subdivisions: [Int] = [0, 1, 4, 8, 12, 16, 24, 32, 48, 96, 128]
	static let sizes: [CGSize] = [CGSize(width: 304, height: 176), CGSize(width: 720, height: 480)]

	static var samples: [MeshSample] {
		var samples: [MeshSample] = MeshSample.all
		for id in ["warped", "organic"] {
			var sample: MeshSample = samples.first(where: { $0.id == id })!
			let view: KHMeshGradientView = KHMeshGradientView()
			sample.apply(to: view)
			sample.id += "-explicit"
			sample.title += " · shared handles"
			sample.bezierPoints = view.resolvedBezierPoints
			samples.append(sample)
		}
		var strong: MeshSample = samples.first(where: { $0.id == "corners" })!
		strong.id = "strong-handles"
		strong.title = "Strong curved boundary"
		strong.detail = "Explicit handles · curved right edge · indigo outside"
		let view: KHMeshGradientView = KHMeshGradientView()
		strong.apply(to: view)
		strong.bezierPoints = view.resolvedBezierPoints
		strong.bezierPoints![1].bottomControlPoint = CGPoint(x: 0.2, y: 0.25)
		strong.bezierPoints![3].topControlPoint = CGPoint(x: 0.2, y: 0.75)
		strong.background = .init(red: 0.2, green: 0.15, blue: 0.4, alpha: 1)
		samples.append(strong)
		let organic: MeshSample = samples.first(where: { $0.id == "organic" })!
		let fixtures: BenchmarkFixtures = BenchmarkFixtures(sample: organic, count: 60, randomSeed: 42)
		for index in [0, 17, 59] {
			var sample: MeshSample = fixtures.samples[index]
			sample.id = "random-\(index)"
			sample.title = "Stress fixture \(index)"
			sample.detail = "4 × 4 · seed 42 · independent geometry and palette"
			samples.append(sample)
		}
		return samples
	}

	@MainActor static func export() throws {
		guard #available(iOS 18.0, *) else { return }

		let directory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("GeometryExperiment", isDirectory: true)
		if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		var captures: [[String: Any]] = []
		for sample in self.samples {
			for size in self.sizes {
				try autoreleasepool {
					let stem: String = "\(sample.id)-\(Int(size.width))x\(Int(size.height))"
					let view: KHMeshGradientView = KHMeshGradientView()
					sample.apply(to: view)
					let reference = ImageRenderer(content: SwiftUIMesh(sample: sample).frame(width: size.width, height: size.height).environment(\.colorScheme, .light))
					reference.scale = 1
					reference.isOpaque = false
					guard let image: UIImage = reference.uiImage, let data: Data = image.pngData() else { throw ExportError.swiftUIImage }

					try data.write(to: directory.appendingPathComponent("\(stem)-swiftui.png"))
					for subdivisions in self.subdivisions {
						view.subdivisions = subdivisions
						try view.renderedImage(size: size).pngData()!.write(to: directory.appendingPathComponent("\(stem)-n\(subdivisions).png"))
					}
					let inputs: BenchmarkFixtures = BenchmarkFixtures(sample: sample, count: 1, randomSeed: nil)
					var input: [String: Any] = inputs.inputs[0]
					input["gridWidth"] = sample.size.width
					input["gridHeight"] = sample.size.height
					input["smoothsColors"] = sample.smoothsColors
					input["colorSpace"] = String(describing: sample.colorSpace)
					input["backgroundRGBA"] = self.rgba(sample.background)
					if let points = sample.bezierPoints {
						input["bezierPoints"] = points.map({ point in
							[point.position, point.leadingControlPoint, point.topControlPoint, point.trailingControlPoint, point.bottomControlPoint].map({ [Double($0.x), Double($0.y)] })
						})
					}
					captures.append(["id": sample.id, "title": sample.title, "stem": stem,
					                 "width": Int(size.width), "height": Int(size.height), "inputs": input])
				}
			}
		}
		let metadata: [String: Any] = ["device": UIDevice.current.model, "os": UIDevice.current.systemVersion,
		                               "subdivisions": self.subdivisions, "captures": captures, "imageScale": 1,
		                               "reference": "SwiftUI ImageRenderer; independent from onscreen GPU benchmarks",
		                               "khReferenceSubdivisions": 128, "colorEvaluation": "per-fragment-mixed-basis; packed-half-opaque-device; float-other-modes",
		                               "adaptiveSubdivisionValue": 0, "maximumGeometryErrorPixels": 0.5]
		try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
		print("GEOMETRY_EXPORT_COMPLETE")
	}

	private static func rgba(_ color: UIColor) -> [Double] {
		var red: CGFloat = 0
		var green: CGFloat = 0
		var blue: CGFloat = 0
		var alpha: CGFloat = 0
		color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
		return [Double(red), Double(green), Double(blue), Double(alpha)]
	}

	private enum ExportError: Error { case swiftUIImage }
}

// MARK: - GeometryProbeViewController

/// A single onscreen SwiftUI mesh changes size/geometry once per second so a
/// debugger can observe its actual RenderBox geometry selection. Never benchmark
/// performance with this diagnostic mode or a debugger attached.
@available(iOS 18.0, *)
final class GeometryProbeViewController: UIViewController {
	private var host: UIHostingController<SwiftUIMesh>?
	private var caseIndex: Int = 0
	private var timer: Timer?
	private let cases: [(String, CGSize)] = ["corners", "organic", "organic-explicit", "strong-handles", "linear-colors"].flatMap({ id in
		[CGSize(width: 152, height: 88), CGSize(width: 360, height: 240)].map({ (id, $0) })
	})

	override func viewDidLoad() {
		super.viewDidLoad()
		self.view.backgroundColor = .white
		UIApplication.shared.isIdleTimerDisabled = true
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		guard self.timer == nil else { return }

		self.advance()
		self.timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true, block: { [weak self] _ in self?.advance() })
	}

	deinit { self.timer?.invalidate() }
	private func advance() {
		guard self.caseIndex < self.cases.count else { self.timer?.invalidate(); self.timer = nil; print("GEOMETRY_PROBE_COMPLETE"); return }

		let (id, size) = self.cases[self.caseIndex]
		let sample: MeshSample = GeometryExperiment.samples.first(where: { $0.id == id })!
		self.host?.willMove(toParent: nil)
		self.host?.view.removeFromSuperview()
		self.host?.removeFromParent()
		let host = UIHostingController(rootView: SwiftUIMesh(sample: sample))
		host.view.backgroundColor = .clear
		self.addChild(host)
		self.view.addSubview(host.view)
		host.view.frame = CGRect(origin: CGPoint(x: 40, y: 80), size: size)
		host.didMove(toParent: self)
		self.host = host
		print("GEOMETRY_PROBE_CASE \(self.caseIndex) \(id) \(Int(size.width))x\(Int(size.height)) scale=\(self.view.window?.screen.scale ?? 1)")
		self.caseIndex += 1
	}
}
