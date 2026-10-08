import Darwin
import KHMeshGradient
import SwiftUI
import UIKit
import os

// MARK: - MeshBenchmarkConfiguration

struct MeshBenchmarkConfiguration {
	var renderer: String
	var count: Int
	var sampleID: String
	var runID: String
	var launchNonce: String
	var requestedFPS: Int
	var activeSeconds: Double
	var startDelay: Double
	var collectsMetalStatistics: Bool
	var cellSize: CGSize
	var randomSeed: UInt64?
	var subdivisions: Int

	static func fromArguments() -> Self? {
		let args: [String] = ProcessInfo.processInfo.arguments
		guard args.contains("--benchmark") else { return nil }

		func value(_ name: String, _ fallback: String) -> String {
			guard let index: Int = args.firstIndex(of: name), index + 1 < args.count else { return fallback }

			return args[index + 1]
		}
		let name: String = value("--bench-id", UUID().uuidString)
		let safeName: String = String(name.filter({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }))
		return Self(renderer: value("--benchmark", "kh"), count: min(64, max(1, Int(value("--bench-count", "5")) ?? 5)),
		            sampleID: value("--bench-mesh", "rainbow"), runID: safeName, launchNonce: value("--bench-token", UUID().uuidString), requestedFPS: min(120, max(1, Int(value("--bench-fps", "60")) ?? 60)),
		            activeSeconds: max(2, Double(value("--bench-seconds", "8")) ?? 8), startDelay: max(0, Double(value("--bench-delay", "0")) ?? 0),
		            collectsMetalStatistics: !args.contains("--bench-no-metal-statistics"),
		            cellSize: CGSize(width: max(32, Double(value("--bench-width", "320")) ?? 320), height: max(32, Double(value("--bench-height", "200")) ?? 200)),
		            randomSeed: UInt64(value("--bench-random-seed", "")),
		            subdivisions: min(128, max(0, Int(value("--bench-subdivisions", "0")) ?? 0)))
	}
}

// MARK: - ProcessMeasurement

private struct ProcessMeasurement: Codable {
	var wallTime: Double
	var cpuSeconds: Double
	var residentBytes: UInt64
	var physicalFootprintBytes: UInt64
	var thermalState: Int
	var lowPowerMode: Bool
	var applicationState: Int

	@MainActor static func capture() -> Self {
		var usage: rusage = rusage()
		getrusage(RUSAGE_SELF, &usage)
		var info: task_vm_info_data_t = task_vm_info_data_t()
		var count: mach_msg_type_number_t = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
		let status: kern_return_t = withUnsafeMutablePointer(to: &info, { pointer in
			pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count), {
				task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
			})
		})
		return Self(wallTime: CACurrentMediaTime(), cpuSeconds:
			Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000,
			residentBytes: status == KERN_SUCCESS ? info.resident_size : 0,
			physicalFootprintBytes: status == KERN_SUCCESS ? info.phys_footprint : 0,
			thermalState: ProcessInfo.processInfo.thermalState.rawValue,
			lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
			applicationState: UIApplication.shared.applicationState.rawValue)
	}
}

// MARK: - BenchmarkPhaseReport

private struct BenchmarkPhaseReport: Codable {
	var name: String
	var start: ProcessMeasurement
	var end: ProcessMeasurement
	var memorySamples: [ProcessMeasurement]
	var callbackIntervalsMS: [Double]
	var deadlineBudgetsMS: [Double]
	var setterDurationsMS: [Double]
	var tickCount: Int
	var updateCount: Int
	var missedRequestedUpdateSlots: Int
	var metalStatistics: [KHMeshGradientView.RenderingStatistics]
	var metalSubmissions: UInt64
}

// MARK: - MeshBenchmarkViewController

/// Each process measures one renderer/count/mesh combination, never the gallery.
/// A single hosting controller contains all SwiftUI meshes, matching normal
/// SwiftUI composition rather than inflating it with one host per mesh.
final class MeshBenchmarkViewController: UIViewController {
	private let configuration: MeshBenchmarkConfiguration
	private let sample: MeshSample
	private let fixtures: BenchmarkFixtures
	private let titleLabel: UILabel = UILabel()
	private let gridContainer: UIView = UIView()
	private var metalViews: [KHMeshGradientView] = []
	private var swiftUIStates: [BenchmarkSwiftUIState] = []
	private var hostingController: UIViewController?
	private var displayLink: CADisplayLink?
	private var currentPhase: String = "baseline"
	private var phaseStart: ProcessMeasurement = .capture()
	private var memorySamples: [ProcessMeasurement] = []
	private var callbackIntervals: [Double] = []
	private var budgets: [Double] = []
	private var setters: [Double] = []
	private var tickCount: Int = 0
	private var updateCount: Int = 0
	private var missedSlots: Int = 0
	private var previousCallback: Double?
	private var lastMemorySample: Double = 0
	private var animationOrigin: Double = 0
	private var frameCountAtPhaseStart: UInt64 = 0
	private var phases: [BenchmarkPhaseReport] = []
	private var buildWallSeconds: Double = 0
	private var layoutIsValid: Bool = true
	private var interruptions: Int = 0
	private var hasStarted: Bool = false
	private var constructed: Bool = false
	private let log: OSLog = OSLog(subsystem: "com.kylehowells.KHMeshGradientExample", category: .pointsOfInterest)
	private var signpostID: OSSignpostID = .invalid

	init(configuration: MeshBenchmarkConfiguration) {
		self.configuration = configuration
		self.sample = MeshSample.all.first(where: { $0.id == configuration.sampleID }) ?? MeshSample.all[1]
		self.fixtures = BenchmarkFixtures(sample: self.sample, count: configuration.count, randomSeed: configuration.randomSeed)
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	override func loadView() { self.view = UIView() }
	override func viewDidLoad() {
		super.viewDidLoad()
		self.view.backgroundColor = .white
		self.titleLabel.numberOfLines = 2
		self.titleLabel.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
		self.view.addSubview(self.titleLabel)
		self.view.addSubview(self.gridContainer)
		UIApplication.shared.isIdleTimerDisabled = true
		NotificationCenter.default.addObserver(self, selector: #selector(self.didResignActive), name: UIApplication.willResignActiveNotification, object: nil)
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		guard !self.hasStarted else { return }

		self.hasStarted = true
		let link: CADisplayLink = CADisplayLink(target: self, selector: #selector(self.tick(_:)))
		link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(self.configuration.requestedFPS), maximum: Float(self.configuration.requestedFPS), preferred: Float(self.configuration.requestedFPS))
		self.displayLink = link
		self.beginPhase("baseline")
		link.add(to: .main, forMode: .common)
	}

	deinit { self.displayLink?.invalidate(); NotificationCenter.default.removeObserver(self) }

	override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()
		let top: CGFloat = self.view.safeAreaInsets.top
		self.titleLabel.frame = CGRect(x: 16, y: top + 4, width: self.view.bounds.width - 32, height: 52)
		self.gridContainer.frame = CGRect(x: 16, y: top + 64, width: self.view.bounds.width - 32,
		                                  height: self.view.bounds.height - top - 80 - self.view.safeAreaInsets.bottom)
		let stride: CGSize = CGSize(width: self.configuration.cellSize.width + 12, height: self.configuration.cellSize.height + 12)
		let columns: Int = max(1, Int((self.gridContainer.bounds.width + 12) / stride.width))
		let rows: Int = (self.configuration.count + columns - 1) / columns
		self.layoutIsValid = CGFloat(rows) * stride.height - 12 <= self.gridContainer.bounds.height && self.gridContainer.bounds.width >= self.configuration.cellSize.width
		for (index, mesh) in self.metalViews.enumerated() {
			mesh.frame = CGRect(x: CGFloat(index % columns) * stride.width, y: CGFloat(index / columns) * stride.height,
			                    width: self.configuration.cellSize.width, height: self.configuration.cellSize.height)
		}
		if let host = self.hostingController as? UIHostingController<BenchmarkSwiftUIGrid> {
			if host.rootView.columns != columns { host.rootView = BenchmarkSwiftUIGrid(states: self.swiftUIStates, columns: columns, cellSize: self.configuration.cellSize) }
			host.view.frame = self.gridContainer.bounds
		}
	}

	private func constructViews() {
		let start: Double = CACurrentMediaTime()
		if self.configuration.renderer == "kh" {
			for fixture in self.fixtures.samples {
				let view: KHMeshGradientView = KHMeshGradientView()
				fixture.apply(to: view)
				view.subdivisions = self.configuration.subdivisions
				self.gridContainer.addSubview(view)
				self.metalViews.append(view)
			}
		}
		else if self.configuration.renderer == "swiftui", #available(iOS 18.0, *) {
			self.swiftUIStates = self.fixtures.samples.map({ BenchmarkSwiftUIState(sample: $0) })
			let columns: Int = max(1, Int((self.gridContainer.bounds.width + 12) / (self.configuration.cellSize.width + 12)))
			let host = UIHostingController(rootView: BenchmarkSwiftUIGrid(states: self.swiftUIStates, columns: columns, cellSize: self.configuration.cellSize))
			host.view.backgroundColor = .clear
			self.addChild(host)
			self.gridContainer.addSubview(host.view)
			host.didMove(toParent: self)
			self.hostingController = host
		}
		self.constructed = true
		self.view.setNeedsLayout()
		self.view.layoutIfNeeded()
		self.buildWallSeconds = CACurrentMediaTime() - start
	}

	private func duration(_ phase: String) -> Double {
		switch phase {
			case "baseline": return 2 + self.configuration.startDelay

			case "warmup": return 2

			case "idle-before", "idle-after": return 3

			case "update-warmup", "settle": return 1

			case "active": return self.configuration.activeSeconds

			default: return 0
		}
	}

	private func beginPhase(_ phase: String) {
		self.currentPhase = phase
		self.titleLabel.text = "\(self.configuration.renderer) · \(self.configuration.count) × \(self.sample.title) · \(self.configuration.requestedFPS) Hz\n\(phase) · \(Int(self.configuration.cellSize.width)) × \(Int(self.configuration.cellSize.height)) pt per mesh"
		self.callbackIntervals.removeAll(keepingCapacity: true)
		self.budgets.removeAll(keepingCapacity: true)
		self.setters.removeAll(keepingCapacity: true)
		self.memorySamples.removeAll(keepingCapacity: true)
		self.tickCount = 0; self.updateCount = 0; self.missedSlots = 0; self.previousCallback = nil
		let measured: Bool = ["idle-before", "active", "idle-after"].contains(phase)
		for view in self.metalViews {
			view.collectsRenderingStatistics = false
			if measured { view.resetRenderingStatistics() }
			view.collectsRenderingStatistics = measured && self.configuration.collectsMetalStatistics
		}
		self.frameCountAtPhaseStart = self.metalViews.reduce(0, { $0 + $1.renderedFrameCount })
		self.phaseStart = .capture()
		self.lastMemorySample = self.phaseStart.wallTime
		self.memorySamples.append(self.phaseStart)
		self.signpostID = OSSignpostID(log: self.log)
		os_signpost(.begin, log: self.log, name: "Benchmark phase", signpostID: self.signpostID, "%{public}@", phase as NSString)
		if phase == "update-warmup" { self.animationOrigin = self.phaseStart.wallTime }
		print("BENCHMARK_PHASE \(self.configuration.runID) \(phase)")
	}

	private func finishPhase() {
		os_signpost(.end, log: self.log, name: "Benchmark phase", signpostID: self.signpostID)
		let end: ProcessMeasurement = .capture()
		self.memorySamples.append(end)
		self.phases.append(BenchmarkPhaseReport(name: self.currentPhase, start: self.phaseStart, end: end,
		                                        memorySamples: self.memorySamples, callbackIntervalsMS: self.callbackIntervals, deadlineBudgetsMS: self.budgets,
		                                        setterDurationsMS: self.setters, tickCount: self.tickCount, updateCount: self.updateCount,
		                                        missedRequestedUpdateSlots: self.missedSlots, metalStatistics: self.metalViews.map({ $0.renderingStatistics }),
		                                        metalSubmissions: self.metalViews.reduce(0, { $0 + $1.renderedFrameCount }) - self.frameCountAtPhaseStart))
		for view in self.metalViews {
			view.collectsRenderingStatistics = false
		}
	}

	@objc private func tick(_ link: CADisplayLink) {
		let now: Double = CACurrentMediaTime()
		if now - self.phaseStart.wallTime >= self.duration(self.currentPhase) {
			self.finishPhase()
			switch self.currentPhase {
				case "baseline": self.constructViews(); self.beginPhase("warmup")

				case "warmup": self.beginPhase("idle-before")

				case "idle-before": self.beginPhase("update-warmup")

				case "update-warmup": self.beginPhase("active")

				case "active": self.beginPhase("settle")

				case "settle":
					// Wait one second before sampling active GPU statistics, so in-flight
					// completions are counted without blocking the measured frame loop.
					if let index: Int = self.phases.firstIndex(where: { $0.name == "active" }) {
						self.phases[index].metalStatistics = self.metalViews.map({ $0.renderingStatistics })
					}
					self.beginPhase("idle-after")

				case "idle-after": self.complete(); return

				default: return
			}
			return
		}
		self.tickCount += 1
		if let previous: Double = self.previousCallback {
			let interval: Double = now - previous
			self.callbackIntervals.append(interval * 1000)
			self.missedSlots += max(0, Int((interval * Double(self.configuration.requestedFPS)).rounded()) - 1)
		}
		self.previousCallback = now
		self.budgets.append((link.targetTimestamp - link.timestamp) * 1000)
		if now - self.lastMemorySample >= 0.25 { self.memorySamples.append(.capture()); self.lastMemorySample = now }
		if self.currentPhase == "active" || self.currentPhase == "update-warmup" {
			let start: Double = CACurrentMediaTime()
			let time: Double = link.targetTimestamp - self.animationOrigin
			for index in 0 ..< self.configuration.count {
				let points: [CGPoint] = self.updatedPoints(time: time, index: index)
				if self.configuration.renderer == "kh" { self.metalViews[index].points = points }
				else if self.configuration.renderer == "swiftui" {
					self.swiftUIStates[index].points = points.map({ SIMD2<Float>(Float($0.x), Float($0.y)) })
				}
			}
			self.setters.append((CACurrentMediaTime() - start) * 1000)
			self.updateCount += 1
		}
	}

	private func updatedPoints(time: Double, index: Int) -> [CGPoint] {
		var points: [CGPoint] = self.fixtures.samples[index].points
		let offset: Double = Double(index) * 0.37
		for y in 1 ..< (self.sample.size.height - 1) {
			for x in 1 ..< (self.sample.size.width - 1) {
				let vertex: Int = y * self.sample.size.width + x
				let amplitude: Double = self.sample.size.width == 3 ? 0.16 : 0.035
				points[vertex].x += amplitude * sin(time * 1.7 + offset + Double(vertex) * 0.21)
				points[vertex].y += amplitude * cos(time * 1.3 + offset + Double(vertex) * 0.13)
			}
		}
		return points
	}

	@objc private func didResignActive() { self.interruptions += 1 }

	private func complete() {
		self.displayLink?.invalidate()
		self.displayLink = nil
		UIApplication.shared.isIdleTimerDisabled = false
		self.titleLabel.text = "Benchmark complete · \(self.configuration.runID)"
		var system: utsname = utsname()
		uname(&system)
		let capacity: Int = MemoryLayout.size(ofValue: system.machine)
		let model: String = withUnsafePointer(to: &system.machine, { pointer in
			pointer.withMemoryRebound(to: CChar.self, capacity: capacity, { String(cString: $0) })
		})
		do {
			let encoder: JSONEncoder = JSONEncoder()
			encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
			let phaseData: Data = try encoder.encode(self.phases)
			let phaseObject: Any = try JSONSerialization.jsonObject(with: phaseData)
			let metadata: [String: Any] = [
				"runID": self.configuration.runID, "launchNonce": self.configuration.launchNonce,
				"renderer": self.configuration.renderer, "count": self.configuration.count,
				"mesh": self.sample.id, "gridWidth": self.sample.size.width, "gridHeight": self.sample.size.height,
				"requestedFPS": self.configuration.requestedFPS, "viewWidthPoints": self.configuration.cellSize.width,
				"viewHeightPoints": self.configuration.cellSize.height, "maximumScreenFPS": self.view.window?.screen.maximumFramesPerSecond ?? 0,
				"displayScale": self.view.window?.screen.scale ?? 1, "screenWidthPoints": self.view.bounds.width,
				"screenHeightPoints": self.view.bounds.height, "os": UIDevice.current.systemVersion, "model": model,
				"isSimulator": self.isSimulator, "build": self.buildConfiguration,
				"metalStatisticsEnabled": self.configuration.collectsMetalStatistics, "subdivisions": self.configuration.subdivisions,
				"geometryResolutionScope": self.configuration.renderer == "kh" ? (self.configuration.subdivisions == 0 ? "adaptive-geometry-in-framebuffer-pixels" : "fixed-subdivisions-per-patch") : "SwiftUI-managed-not-configurable",
				"metalColorEvaluation": "per-fragment-mixed-basis; packed-half-opaque-device; float-other-modes",
				"maximumGeometryErrorPixels": 0.5,
				"metalGPUTimeAllocation": "equal-share-of-batch",
				"metalMaximumDrawablesPerLayer": 3, "metalTriangleEncoding": "indexed",
				"metalRenderPassBatching": "multiple-color-attachments",
				"constructionWallSeconds": self.buildWallSeconds, "allMeshesVisible": self.layoutIsValid,
				"interruptions": self.interruptions, "swiftUIHostingControllers": self.hostingController == nil ? 0 : 1,
				"phases": phaseObject,
				"gradientVariant": self.configuration.randomSeed == nil ? "shared-fixture" : "randomized-per-view",
				"randomSeed": self.configuration.randomSeed.map({ String($0) }) ?? "none",
				"uniqueFixtureCount": Set(self.fixtures.fingerprints).count,
				"fixtureSHA256": self.fixtures.fingerprint, "perViewFixtureSHA256": self.fixtures.fingerprints,
				"fixtureInputs": self.fixtures.inputs,
			]
			let directory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Benchmarks", isDirectory: true)
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
			try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("\(self.configuration.runID).json"), options: .atomic)
			print("BENCHMARK_COMPLETE \(self.configuration.runID)")
		}
		catch { print("BENCHMARK_FAILED \(error)") }
	}

	private var isSimulator: Bool {
		#if targetEnvironment(simulator)
			return true
		#else
			return false
		#endif
	}

	private var buildConfiguration: String {
		#if DEBUG
			return "Debug"
		#else
			return "Release"
		#endif
	}
}

// MARK: - BenchmarkSwiftUIState

private final class BenchmarkSwiftUIState: ObservableObject {
	@Published var points: [SIMD2<Float>]
	let width: Int
	let height: Int
	let colors: [Color]
	init(sample: MeshSample) {
		self.points = sample.points.map({ SIMD2<Float>(Float($0.x), Float($0.y)) })
		self.width = sample.size.width
		self.height = sample.size.height
		self.colors = sample.colors.map({ Color(uiColor: $0) })
	}
}

// MARK: - BenchmarkSwiftUIGrid

private struct BenchmarkSwiftUIGrid: View {
	var states: [BenchmarkSwiftUIState]
	var columns: Int
	var cellSize: CGSize
	var body: some View {
		ZStack(alignment: .topLeading, content: {
			ForEach(self.states.indices, id: \.self, content: { index in
				BenchmarkSwiftUIMesh(state: self.states[index])
					.frame(width: self.cellSize.width, height: self.cellSize.height)
					.offset(x: CGFloat(index % self.columns) * (self.cellSize.width + 12), y: CGFloat(index / self.columns) * (self.cellSize.height + 12))
			})
		})
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.ignoresSafeArea()
	}
}

// MARK: - BenchmarkSwiftUIMesh

private struct BenchmarkSwiftUIMesh: View {
	@ObservedObject var state: BenchmarkSwiftUIState
	var body: some View {
		if #available(iOS 18.0, *) {
			MeshGradient(width: self.state.width, height: self.state.height, points: self.state.points,
			             colors: self.state.colors, smoothsColors: true, colorSpace: .device)
		}
		else { Color.clear }
	}
}
