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
        ),
        .executable(
            name: "ConfigGen",
            targets: ["ConfigGen"]
        ),
        .executable(
            name: "SQLDocTestsRunner",
            targets: ["SQLDocTestsRunner"]
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
        // Build-time only: reads sqldoc.db, writes Sources/SQLDocCore/Generated/.
        .executableTarget(
            name: "ConfigGen",
            dependencies: [],
            path: "Sources/ConfigGen",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SQLDocTestsRunner",
            dependencies: ["SQLDocCore"],
            path: "Tests/SQLDocTestsRunner"
        )
    ]
)
