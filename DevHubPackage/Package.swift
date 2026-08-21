// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DevHubCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DevHubCore", targets: ["DevHubCore"]),
        .executable(name: "DevHubFixtureTool", targets: ["DevHubFixtureTool"]),
    ],
    targets: [
        .target(
            name: "DevHubCore",
            dependencies: [],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "DevHubFixtureTool",
            dependencies: ["DevHubCore"]
        ),
        .testTarget(
            name: "DevHubCoreTests",
            dependencies: ["DevHubCore"]
        ),
    ]
)
