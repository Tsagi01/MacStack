// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacStack",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacStack", targets: ["MacStackApp"]),
        .executable(name: "macstackctl", targets: ["MacStackCLI"]),
        .library(name: "MacStackCore", targets: ["MacStackCore"])
    ],
    targets: [
        .target(name: "MacStackCore"),
        .executableTarget(name: "MacStackApp", dependencies: ["MacStackCore"]),
        .executableTarget(name: "MacStackCLI", dependencies: ["MacStackCore"]),
        .testTarget(name: "MacStackCoreTests", dependencies: ["MacStackCore"])
    ]
)
