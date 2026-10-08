import KHMeshGradient
import UIKit

struct MeshSample {
	var id: String
	var title: String
	var detail: String
	var size: KHMeshGradientView.MeshSize
	var points: [CGPoint]
	var bezierPoints: [KHMeshGradientView.BezierPoint]?
	var colors: [UIColor]
	var background: UIColor = .clear
	var smoothsColors: Bool = true
	var colorSpace: KHMeshGradientView.ColorSpace = .device

	func apply(to view: KHMeshGradientView) {
		view.meshSize = self.size
		view.points = self.points
		view.bezierPoints = self.bezierPoints
		view.colors = self.colors
		view.meshBackgroundColor = self.background
		view.smoothsColors = self.smoothsColors
		view.colorSpace = self.colorSpace
	}

	static func grid(_ width: Int, _ height: Int) -> [CGPoint] {
		(0 ..< (width * height)).map({ CGPoint(x: CGFloat($0 % width) / CGFloat(width - 1), y: CGFloat($0 / width) / CGFloat(height - 1)) })
	}

	static var all: [MeshSample] {
		let purple: UIColor = UIColor(red: 0.686, green: 0.322, blue: 0.871, alpha: 1)
		let mint: UIColor = UIColor(red: 0, green: 0.78, blue: 0.745, alpha: 1)
		let orange: UIColor = UIColor(red: 1, green: 0.584, blue: 0, alpha: 1)
		let blue: UIColor = UIColor(red: 0, green: 0.478, blue: 1, alpha: 1)
		let pink: UIColor = UIColor(red: 1, green: 0.176, blue: 0.333, alpha: 1)
		let yellow: UIColor = UIColor(red: 1, green: 0.8, blue: 0, alpha: 1)
		let indigo: UIColor = UIColor(red: 0.345, green: 0.337, blue: 0.839, alpha: 1)
		let corners: [UIColor] = [purple, mint, orange, blue]
		let rainbow: [UIColor] = [.red, purple, indigo, orange, .white, blue, yellow, .green, mint]
		let grid2: [CGPoint] = self.grid(2, 2)
		let grid3: [CGPoint] = self.grid(3, 3)
		var warped: [CGPoint] = grid3
		warped[4] = CGPoint(x: 0.72, y: 0.28)
		let curved: [CGPoint] = [
			CGPoint(x: 0, y: 0), CGPoint(x: 0.3, y: 0), CGPoint(x: 0.7, y: 0), CGPoint(x: 1, y: 0),
			CGPoint(x: 0, y: 0.3), CGPoint(x: 0.2, y: 0.4), CGPoint(x: 0.7, y: 0.2), CGPoint(x: 1, y: 0.3),
			CGPoint(x: 0, y: 0.7), CGPoint(x: 0.3, y: 0.8), CGPoint(x: 0.7, y: 0.6), CGPoint(x: 1, y: 0.7),
			CGPoint(x: 0, y: 1), CGPoint(x: 0.3, y: 1), CGPoint(x: 0.7, y: 1), CGPoint(x: 1, y: 1),
		]
		var handles: [KHMeshGradientView.BezierPoint] = grid2.map({
			KHMeshGradientView.BezierPoint(position: $0, leadingControlPoint: $0, topControlPoint: $0, trailingControlPoint: $0, bottomControlPoint: $0)
		})
		handles[2].topControlPoint = CGPoint(x: 0, y: 0.4)
		handles[2].trailingControlPoint = CGPoint(x: 0.9, y: 1)
		return [
			MeshSample(id: "corners", title: "Four corners", detail: "2 × 2 · device colors · smooth", size: .init(width: 2, height: 2), points: grid2, colors: corners),
			MeshSample(id: "rainbow", title: "Rainbow", detail: "3 × 3 · regular grid · smooth", size: .init(width: 3, height: 3), points: grid3, colors: rainbow),
			MeshSample(id: "warped", title: "Moved center", detail: "3 × 3 · center at (0.72, 0.28)", size: .init(width: 3, height: 3), points: warped, colors: rainbow),
			MeshSample(id: "organic", title: "Organic", detail: "4 × 4 · irregular interior points", size: .init(width: 4, height: 4), points: curved,
			           colors: [purple, indigo, purple, yellow, pink, purple, pink, yellow, orange, pink, yellow, orange, yellow, orange, pink, purple]),
			MeshSample(id: "bezier", title: "Explicit Bézier handles", detail: "2 × 2 · stretched orange corner", size: .init(width: 2, height: 2), points: grid2, bezierPoints: handles, colors: corners),
			MeshSample(id: "linear-colors", title: "Unsmoothed colors", detail: "3 × 3 · smoothsColors = false", size: .init(width: 3, height: 3), points: grid3, colors: rainbow, smoothsColors: false),
			MeshSample(id: "background", title: "Outside the mesh", detail: "Inset corner · indigo background fill", size: .init(width: 2, height: 2),
			           points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 0.8, y: 0.9)], colors: corners, background: indigo),
			MeshSample(id: "opacity", title: "Transparency", detail: "Per-vertex alpha · clear background", size: .init(width: 2, height: 2), points: grid2,
			           colors: [purple.withAlphaComponent(0.6), mint.withAlphaComponent(0.7), orange.withAlphaComponent(0.5), blue.withAlphaComponent(0.8)]),
			MeshSample(id: "perceptual", title: "Perceptual color space", detail: "Oklab vs Apple's perceptual interpolation", size: .init(width: 2, height: 2), points: grid2, colors: corners, colorSpace: .perceptual),
		]
	}
}
