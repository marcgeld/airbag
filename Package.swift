// swift-tools-version: 6.4
import PackageDescription

let concurrencySettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"), // SE-0461
    .enableUpcomingFeature("InferIsolatedConformances"),      // SE-0470
]

let package = Package(
    name: "airbag",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "airbag", targets: ["airbag"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
    ],
    targets: [
        .target(
            name: "CSandbox",
            linkerSettings: [.linkedLibrary("sandbox")]
        ),
        .executableTarget(
            name: "airbag",
            dependencies: [
                "CSandbox",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: concurrencySettings
        ),
        .testTarget(
            name: "airbagTests",
            dependencies: ["airbag"],
            swiftSettings: concurrencySettings
        ),
    ]
)
