// swift-tools-version: 5.9
import PackageDescription

let package = Package(
	name: "KHMeshGradient",
	platforms: [.iOS(.v15), .macCatalyst(.v15)],
	products: [.library(name: "KHMeshGradient", targets: ["KHMeshGradient"])],
	targets: [
		.target(name: "KHMeshGradient", resources: [.copy("Resources/MeshShaders.metal")]),
		.testTarget(name: "KHMeshGradientTests", dependencies: ["KHMeshGradient"]),
	]
)
