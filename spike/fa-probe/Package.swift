// swift-tools-version: 6.0
import PackageDescription

// Spike: does FluidAudio resolve, build, and expose a streaming API we can drive
// from a realtime audio pipeline? Validates the integration before committing to
// a SwiftPM migration of the real app.
let package = Package(
    name: "fa-probe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5")
    ],
    targets: [
        .executableTarget(
            name: "fa-probe",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")])
    ]
)
