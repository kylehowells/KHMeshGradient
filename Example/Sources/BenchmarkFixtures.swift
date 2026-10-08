import CryptoKit
import UIKit

// MARK: - BenchmarkFixtures

/// Inputs are prepared before any timed updates. The same seed gives both
/// renderers exactly the same per-view geometry and palette.
struct BenchmarkFixtures {
	let samples: [MeshSample]
	let inputs: [[String: Any]]
	let fingerprints: [String]
	let fingerprint: String

	init(sample: MeshSample, count: Int, randomSeed: UInt64?) {
		var random: BenchmarkRandom = BenchmarkRandom(state: randomSeed ?? 0)
		self.samples = (0 ..< count).map({ _ in
			guard randomSeed != nil else { return sample }

			var varied: MeshSample = sample
			for y in 1 ..< (sample.size.height - 1) {
				for x in 1 ..< (sample.size.width - 1) {
					let vertex: Int = y * sample.size.width + x
					var point: CGPoint = sample.points[vertex]
					point.x += (random.unit() * 2 - 1) * 0.045
					point.y += (random.unit() * 2 - 1) * 0.045
					varied.points[vertex] = point
				}
			}
			varied.colors = sample.colors.map({ _ in
				let hsv: UIColor = UIColor(hue: random.unit(), saturation: 0.65 + random.unit() * 0.35,
				                           brightness: 0.65 + random.unit() * 0.35, alpha: 1)
				var red: CGFloat = 0
				var green: CGFloat = 0
				var blue: CGFloat = 0
				var alpha: CGFloat = 0
				hsv.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
				return UIColor(red: red, green: green, blue: blue, alpha: alpha)
			})
			return varied
		})
		self.inputs = self.samples.map({ fixture in
			[
				"points": fixture.points.map({ [Double($0.x), Double($0.y)] }),
				"colorsRGBA": fixture.colors.map({ color -> [Double] in
					var red: CGFloat = 0
					var green: CGFloat = 0
					var blue: CGFloat = 0
					var alpha: CGFloat = 0
					color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
					return [Double(red), Double(green), Double(blue), Double(alpha)]
				}),
			]
		})
		self.fingerprints = self.inputs.map({ Self.digest($0) })
		self.fingerprint = Self.digest(self.inputs)
	}

	private static func digest(_ value: Any) -> String {
		let data: Data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
		return SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined()
	}
}

// MARK: - BenchmarkRandom

private struct BenchmarkRandom {
	var state: UInt64
	mutating func unit() -> CGFloat {
		self.state &+= 0x9E3779B97F4A7C15
		var value: UInt64 = self.state
		value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
		value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
		value ^= value >> 31
		return CGFloat(value >> 40) / CGFloat(1 << 24)
	}
}
