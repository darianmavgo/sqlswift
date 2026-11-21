// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SqlSwift",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SQLDocCore",
            targets: ["SQLDocCore"]
        ),
        .executable(
            name: "sqlswift",
            targets: ["SQLDocCLI"]
        ),
        .executable(
            name: "SqlSwiftApp",
            targets: ["SQLDocApp"]
        ),
        .executable(
            name: "FileStudio",
            targets: ["FileStudioApp"]
        ),
        .library(
            name: "FileStudioKit",
            targets: ["FileStudioKit"]
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
        // FileStudio: backup-to-R2 and reclaim UI over a filestudio db (the Go worker does the work).
        .target(
            name: "FileStudioKit",
            dependencies: ["SQLDocCore"],
            path: "Sources/FileStudioKit"
        ),
        .executableTarget(
            name: "FileStudioApp",
            dependencies: ["FileStudioKit"],
            path: "Sources/FileStudioApp"
        ),
        .testTarget(
            name: "FileStudioKitTests",
            dependencies: ["FileStudioKit", "SQLDocCore"],
            path: "Tests/FileStudioKitTests"
        ),
        // Build-time only: reads sqldoc.db, writes Sources/SQLDocCore/Generated/.
        .executableTarget(
            name: "ConfigGen",
            dependencies: [],
            path: "Sources/ConfigGen",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Dev-time only: checks and reports on docs/conformance/conformance.db.
        .executableTarget(
            name: "ConformanceGen",
            dependencies: [],
            path: "Sources/ConformanceGen",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SQLDocTestsRunner",
            dependencies: ["SQLDocCore"],
            path: "Tests/SQLDocTestsRunner"
        ),
        // `swift test`: headless UI tests over the app's view models (Swift Testing).
        .testTarget(
            name: "SQLDocAppTests",
            dependencies: ["SQLDocApp", "SQLDocCore"],
            path: "Tests/SQLDocAppTests",
            resources: [.copy("banquet-ui-cases.json")]
        )
    ]
)
