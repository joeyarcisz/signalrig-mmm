// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FitEngine",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "FitEngine", targets: ["FitEngine"]),
        .executable(name: "fitengine-cli", targets: ["fitengine-cli"])
    ],
    targets: [
        .target(
            name: "FitEngine",
            dependencies: []
        ),
        .executableTarget(
            name: "fitengine-cli",
            dependencies: ["FitEngine"]
        ),
        .testTarget(
            name: "FitEngineTests",
            dependencies: ["FitEngine"]
        )
    ]
)
