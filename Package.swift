// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sqldoc",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SQLDocCore",
            targets: ["SQLDocCore"]
        ),
        .executable(
            name: "sqldoc",
            targets: ["SQLDocCLI"]
        ),
        .executable(
            name: "SQLDocApp",
            targets: ["SQLDocApp"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "SQLDocCore",
            dependencies: [],
            path: "Sources/SQLDocCore"
        ),
        .executableTarget(
            name: "SQLDocCLI",
            dependencies: ["SQLDocCore"],
            path: "Sources/SQLDocCLI"
        ),
        .executableTarget(
            name: "SQLDocApp",
            dependencies: ["SQLDocCore"],
            path: "Sources/SQLDocApp"
        ),
        .testTarget(
            name: "SQLDocTests",
            dependencies: ["SQLDocCore"],
            path: "Tests/SQLDocTests"
        )
    ]
)
