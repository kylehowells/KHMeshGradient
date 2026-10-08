import KHMeshGradient
import SwiftUI
import UIKit

enum ComparisonExporter {
	@MainActor static func export() throws {
		guard #available(iOS 18.0, *) else { return }

		let directory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Comparisons", isDirectory: true)
		// This directory belongs exclusively to the example's generated captures.
		if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		var manifest: [[String: String]] = []
		let size: CGSize = CGSize(width: 360, height: 240)
		for sample in MeshSample.all {
			let view: KHMeshGradientView = KHMeshGradientView()
			sample.apply(to: view)
			let ours: UIImage = try view.renderedImage(size: size)
			let reference = ImageRenderer(content: SwiftUIMesh(sample: sample).frame(width: size.width, height: size.height).environment(\.colorScheme, .light))
			reference.scale = 1
			reference.isOpaque = false
			guard let swiftUIImage: UIImage = reference.uiImage else {
				throw NSError(domain: "ComparisonExporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "SwiftUI did not render \(sample.id)"])
			}

			try ours.pngData()!.write(to: directory.appendingPathComponent("\(sample.id)-kh.png"))
			try swiftUIImage.pngData()!.write(to: directory.appendingPathComponent("\(sample.id)-swiftui.png"))
			// A diagnostic reference with our generated handles supplied explicitly
			// separates automatic-handle inference from patch rendering differences.
			if sample.id == "warped" || sample.id == "organic" {
				var explicit: MeshSample = sample
				explicit.bezierPoints = view.resolvedBezierPoints
				let explicitRenderer = ImageRenderer(content: SwiftUIMesh(sample: explicit).frame(width: size.width, height: size.height))
				explicitRenderer.scale = 1
				if let image: UIImage = explicitRenderer.uiImage {
					try image.pngData()!.write(to: directory.appendingPathComponent("\(sample.id)-explicit-swiftui.png"))
				}
			}
			manifest.append(["id": sample.id, "title": sample.title, "detail": sample.detail])
			view.debugMode = .controlPoints
			try view.renderedImage(size: size).pngData()!.write(to: directory.appendingPathComponent("\(sample.id)-debug.png"))
		}
		let metadata: [String: Any] = ["device": UIDevice.current.model, "os": UIDevice.current.systemVersion,
		                               "width": Int(size.width), "height": Int(size.height), "samples": manifest]
		try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("manifest.json"))
		print("COMPARISON_EXPORT_COMPLETE: \(directory.path)")
	}
}
