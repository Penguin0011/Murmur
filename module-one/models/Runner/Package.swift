// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ModelBench", platforms: [.macOS(.v14)], dependencies: [
    .package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7")
], targets: [.executableTarget(name: "ModelBench", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")])])
