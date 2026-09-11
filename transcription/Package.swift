// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "transcribe",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4")
    ],
    targets: [
        .executableTarget(
            name: "transcribe",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ]
        ),
        .target(
            name: "LongToShortCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ]
        ),
        .executableTarget(
            name: "LongToShortApp",
            dependencies: [
                "LongToShortCore"
            ]
        ),
        .executableTarget(
            name: "score-test",
            dependencies: [
                "LongToShortCore"
            ]
        ),
    ]
)
