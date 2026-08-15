// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DevHubCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DevHubCore", targets: ["DevHubCore"]),
    ],
    targets: [
        .target(
            name: "DevHubCore",
            dependencies: []
        ),
        .testTarget(
            name: "DevHubCoreTests",
            dependencies: ["DevHubCore"]
        ),
    ]
)
