import KHMeshGradient
import SwiftUI

@available(iOS 18.0, *)
struct SwiftUIMesh: View {
	var sample: MeshSample
	var body: some View {
		let locations: MeshGradient.Locations
		if let points: [KHMeshGradientView.BezierPoint] = self.sample.bezierPoints {
			locations = .bezierPoints(points.map({ point in
				MeshGradient.BezierPoint(
					position: Self.vector(point.position), leadingControlPoint: Self.vector(point.leadingControlPoint),
					topControlPoint: Self.vector(point.topControlPoint), trailingControlPoint: Self.vector(point.trailingControlPoint),
					bottomControlPoint: Self.vector(point.bottomControlPoint)
				)
			}))
		}
		else { locations = .points(self.sample.points.map(Self.vector)) }
		return MeshGradient(width: self.sample.size.width, height: self.sample.size.height,
			locations: locations, colors: .colors(self.sample.colors.map({ Color(uiColor: $0) })),
			background: Color(uiColor: self.sample.background), smoothsColors: self.sample.smoothsColors,
			colorSpace: self.sample.colorSpace == .perceptual ? .perceptual : .device)
	}
	private static func vector(_ p: CGPoint) -> SIMD2<Float> { SIMD2<Float>(Float(p.x), Float(p.y)) }
}

final class MeshSampleState: ObservableObject {
	@Published var sample: MeshSample
	init(sample: MeshSample) { self.sample = sample }
}

@available(iOS 18.0, *)
struct ObservedSwiftUIMesh: View {
	@ObservedObject var state: MeshSampleState
	var body: some View { SwiftUIMesh(sample: self.state.sample) }
}
