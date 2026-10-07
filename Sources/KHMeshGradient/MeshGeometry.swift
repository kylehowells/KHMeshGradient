import UIKit
import simd

/// CPU-side patch construction. The GPU evaluates the resulting bicubic surfaces.
enum MeshGeometry {
	private static let resolvedColorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.extendedSRGB)!
	struct Snapshot: Equatable {
		var size: KHMeshGradientView.MeshSize
		var vertices: [KHMeshGradientView.BezierPoint]
		var colors: [SIMD4<Float>]
		var background: SIMD4<Float>
		var smoothsColors: Bool
		var colorSpace: KHMeshGradientView.ColorSpace
		var debugMode: KHMeshGradientView.DebugMode
		var subdivisions: Int
	}

	static func automaticVertices(points: [CGPoint], size: KHMeshGradientView.MeshSize) -> [KHMeshGradientView.BezierPoint] {
		guard size.width >= 2, size.height >= 2, points.count == size.vertexCount else { return [] }
		return points.indices.map({ index in
			let x: Int = index % size.width
			let y: Int = index / size.width
			let p: SIMD2<Float> = self.vector(points[index])
			let beforeX: SIMD2<Float> = x > 0 ? self.vector(points[index - 1]) : p
			let afterX: SIMD2<Float> = x + 1 < size.width ? self.vector(points[index + 1]) : p
			let beforeY: SIMD2<Float> = y > 0 ? self.vector(points[index - size.width]) : p
			let afterY: SIMD2<Float> = y + 1 < size.height ? self.vector(points[index + size.width]) : p
			let dx: SIMD2<Float> = (afterX - beforeX) / ((x == 0 || x == size.width - 1) ? 3 : 6)
			let dy: SIMD2<Float> = (afterY - beforeY) / ((y == 0 || y == size.height - 1) ? 3 : 6)
			return KHMeshGradientView.BezierPoint(
				position: points[index],
				leadingControlPoint: self.point(p - dx),
				topControlPoint: self.point(p - dy),
				trailingControlPoint: self.point(p + dx),
				bottomControlPoint: self.point(p + dy)
			)
		})
	}

	/// Four boundary Bézier curves, with the interior of the Coons surface converted
	/// to a bicubic control net. Shared boundaries agree exactly between patches.
	static func positionNet(_ tl: KHMeshGradientView.BezierPoint, _ tr: KHMeshGradientView.BezierPoint,
		_ bl: KHMeshGradientView.BezierPoint, _ br: KHMeshGradientView.BezierPoint) -> [SIMD4<Float>] {
		let top = simd_float4x2(columns: (self.vector(tl.position), self.vector(tl.trailingControlPoint), self.vector(tr.leadingControlPoint), self.vector(tr.position)))
		let bottom = simd_float4x2(columns: (self.vector(bl.position), self.vector(bl.trailingControlPoint), self.vector(br.leadingControlPoint), self.vector(br.position)))
		let left = simd_float4x2(columns: (self.vector(tl.position), self.vector(tl.bottomControlPoint), self.vector(bl.topControlPoint), self.vector(bl.position)))
		let right = simd_float4x2(columns: (self.vector(tr.position), self.vector(tr.bottomControlPoint), self.vector(br.topControlPoint), self.vector(br.position)))
		var result: [SIMD4<Float>] = []
		result.reserveCapacity(16)
		for y in 0..<4 {
			let v: Float = Float(y) / 3
			for x in 0..<4 {
				let u: Float = Float(x) / 3
				let bilinear: SIMD2<Float> = self.mix(self.mix(top[0], top[3], u), self.mix(bottom[0], bottom[3], u), v)
				let p: SIMD2<Float> = self.mix(top[x], bottom[x], v) + self.mix(left[y], right[y], u) - bilinear
				result.append(SIMD4<Float>(p.x, p.y, 0, 0))
			}
		}
		return result
	}

	static func colorPatchData(_ mesh: Snapshot) -> [SIMD4<Float>] {
		let w: Int = mesh.size.width
		let h: Int = mesh.size.height
		let colors: [SIMD4<Float>] = mesh.colors.map({
			let c: SIMD4<Float> = self.interpolationColor($0, space: mesh.colorSpace)
			return SIMD4<Float>(c.x * c.w, c.y * c.w, c.z * c.w, c.w)
		})
		func color(_ x: Int, _ y: Int) -> SIMD4<Float> { colors[y * w + x] }
		func tangent(_ before: SIMD4<Float>, _ current: SIMD4<Float>, _ after: SIMD4<Float>) -> SIMD4<Float> {
			var result: SIMD4<Float> = (after - before) * 0.5
			for component in 0..<4 {
				let a: Float = current[component] - before[component]
				let b: Float = after[component] - current[component]
				// Preserve extrema rather than pulling a saturated color past its value.
				if a * b <= 0 { result[component] = 0 }
				else {
					let limit: Float = 3 * min(abs(a), abs(b))
					result[component] = min(limit, max(-limit, result[component]))
				}
			}
			return result
		}
		func dx(_ x: Int, _ y: Int) -> SIMD4<Float> {
			if x == 0 || x == w - 1 { return .zero }
			return tangent(color(x - 1, y), color(x, y), color(x + 1, y))
		}
		func dy(_ x: Int, _ y: Int) -> SIMD4<Float> {
			if y == 0 || y == h - 1 { return .zero }
			return tangent(color(x, y - 1), color(x, y), color(x, y + 1))
		}
		func dxy(_ x: Int, _ y: Int) -> SIMD4<Float> {
			if x == 0 || x == w - 1 || y == 0 || y == h - 1 { return .zero }
			return (color(x + 1, y + 1) - color(x - 1, y + 1) - color(x + 1, y - 1) + color(x - 1, y - 1)) * 0.25
		}
		var result: [SIMD4<Float>] = []
		result.reserveCapacity((w - 1) * (h - 1) * 16)
		for y in 0..<(h - 1) {
			for x in 0..<(w - 1) {
				let c00: SIMD4<Float> = color(x, y)
				let c10: SIMD4<Float> = color(x + 1, y)
				let c01: SIMD4<Float> = color(x, y + 1)
				let c11: SIMD4<Float> = color(x + 1, y + 1)
				var net: [SIMD4<Float>] = []
				net.reserveCapacity(16)
				for j in 0..<4 {
					let v: Float = Float(j) / 3
					for i in 0..<4 {
						let u: Float = Float(i) / 3
						net.append(self.mix(self.mix(c00, c10, u), self.mix(c01, c11, u), v))
					}
				}
				if mesh.smoothsColors {
					net[1] = c00 + dx(x, y) / 3
					net[2] = c10 - dx(x + 1, y) / 3
					net[4] = c00 + dy(x, y) / 3
					net[8] = c01 - dy(x, y + 1) / 3
					net[7] = c10 + dy(x + 1, y) / 3
					net[11] = c11 - dy(x + 1, y + 1) / 3
					net[13] = c01 + dx(x, y + 1) / 3
					net[14] = c11 - dx(x + 1, y + 1) / 3
					net[5] = net[1] + net[4] - c00 + dxy(x, y) / 9
					net[6] = net[2] + net[7] - c10 - dxy(x + 1, y) / 9
					net[9] = net[8] + net[13] - c01 - dxy(x, y + 1) / 9
					net[10] = net[11] + net[14] - c11 + dxy(x + 1, y + 1) / 9
				}
				result += net
			}
		}
		return result
	}

	static func patchData(_ mesh: Snapshot, colorNets: [SIMD4<Float>]? = nil) -> [SIMD4<Float>] {
		let colors = colorNets ?? self.colorPatchData(mesh)
		let w = mesh.size.width, h = mesh.size.height
		var result: [SIMD4<Float>] = []
		result.reserveCapacity((w - 1) * (h - 1) * 32)
		var colorOffset = 0
		for y in 0..<(h - 1) {
			for x in 0..<(w - 1) {
				let a = y * w + x
				result.append(contentsOf: self.positionNet(mesh.vertices[a], mesh.vertices[a + 1], mesh.vertices[a + w], mesh.vertices[a + w + 1]))
				result.append(contentsOf: colors[colorOffset..<(colorOffset + 16)])
				colorOffset += 16
			}
		}
		return result
	}

	static func evaluate(_ net: [SIMD4<Float>], u: Float, v: Float) -> SIMD4<Float> {
		func weights(_ t: Float) -> [Float] {
			let s: Float = 1 - t
			return [s * s * s, 3 * s * s * t, 3 * s * t * t, t * t * t]
		}
		let bu: [Float] = weights(u)
		let bv: [Float] = weights(v)
		var result: SIMD4<Float> = .zero
		for y in 0..<4 { for x in 0..<4 { result += net[y * 4 + x] * bu[x] * bv[y] } }
		return result
	}

	static func vector(_ p: CGPoint) -> SIMD2<Float> { SIMD2<Float>(Float(p.x), Float(p.y)) }
	static func point(_ p: SIMD2<Float>) -> CGPoint { CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)) }
	static func mix<T: SIMD>(_ a: T, _ b: T, _ t: T.Scalar) -> T where T.Scalar: BinaryFloatingPoint { a + (b - a) * t }

	static func rgba(_ color: CGColor) -> SIMD4<Float> {
		guard let converted: CGColor = color.converted(to: self.resolvedColorSpace, intent: .relativeColorimetric, options: nil),
			let c: [CGFloat] = converted.components, c.count >= 4 else { return .zero }
		return SIMD4<Float>(Float(c[0]), Float(c[1]), Float(c[2]), Float(c[3]))
	}

	static func interpolationColor(_ c: SIMD4<Float>, space: KHMeshGradientView.ColorSpace) -> SIMD4<Float> {
		guard space != .device else { return c }
		func linear(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
		let rgb: SIMD3<Float> = SIMD3<Float>(linear(c.x), linear(c.y), linear(c.z))
		if space == .linear { return SIMD4<Float>(rgb.x, rgb.y, rgb.z, c.w) }
		let l: Float = cbrt(simd_dot(rgb, SIMD3<Float>(0.4122214708, 0.5363325363, 0.0514459929)))
		let m: Float = cbrt(simd_dot(rgb, SIMD3<Float>(0.2119034982, 0.6806995451, 0.1073969566)))
		let s: Float = cbrt(simd_dot(rgb, SIMD3<Float>(0.0883024619, 0.2817188376, 0.6299787005)))
		return SIMD4<Float>(
			0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
			1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
			0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s, c.w
		)
	}
}
