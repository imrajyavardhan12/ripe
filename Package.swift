// swift-tools-version: 6.0
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny")
]

let package = Package(
    name: "ripe",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ripe", targets: ["ripe"]),
        .library(name: "RipeCore", targets: ["RipeCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2")
    ],
    targets: [
        .target(name: "RipeCore", swiftSettings: swiftSettings),
        .target(
            name: "RipeCLI",
            dependencies: [
                "RipeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(name: "ripe", dependencies: ["RipeCLI"], swiftSettings: swiftSettings),
        .testTarget(
            name: "RipeCoreTests",
            dependencies: ["RipeCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),
        .testTarget(name: "RipeCLITests", dependencies: ["RipeCLI"], swiftSettings: swiftSettings),
    ]
)
