// swift-tools-version: 6.1
//
// WorkflowHost — a local daemon that orchestrates Claude Code runs across repos.
//
// NOTE: this package is unrelated to workflow-manager.xcodeproj in the same
// directory. They share no code and neither depends on the other. See CLAUDE.md.

import PackageDescription

let package = Package(
    name: "WorkflowHost",
    platforms: [
        .macOS(.v15),
        // iOS is declared only so WorkflowCore can be consumed by
        // Apps/MobileClient in phase 5. Nothing else targets iOS.
        .iOS(.v18),
    ],
    products: [
        .library(name: "WorkflowCore", targets: ["WorkflowCore"]),
        .executable(name: "WorkflowHost", targets: ["WorkflowHost"]),
        .executable(name: "HostApp", targets: ["HostApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.122.0"),
    ],
    targets: [
        // Models and DTOs. No I/O, no dependencies. Shared with both clients.
        .target(
            name: "WorkflowCore",
            path: "Packages/WorkflowCore/Sources/WorkflowCore"
        ),

        // All daemon logic lives here rather than in the executable target, so
        // it can be depended on by tests. Do not collapse this split.
        .target(
            name: "WorkflowHostKit",
            dependencies: [
                "WorkflowCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Vapor", package: "vapor"),
            ],
            path: "Packages/WorkflowHost/Sources/WorkflowHostKit",
            // Plain HTML with no build step, copied verbatim.
            resources: [.copy("Resources")]
        ),

        // Thin entry point: error reporting and exit codes only.
        .executableTarget(
            name: "WorkflowHost",
            dependencies: ["WorkflowHostKit"],
            path: "Packages/WorkflowHost/Sources/WorkflowHost"
        ),

        // macOS menu bar client. An SPM executable rather than an .xcodeproj
        // app: it spawns claude/git/cloudflared, so it can never be sandboxed,
        // and an accessory-policy NSApplication is all a status item needs.
        .executableTarget(
            name: "HostApp",
            dependencies: ["WorkflowHostKit", "WorkflowCore"],
            path: "Apps/HostApp/Sources/HostApp"
        ),

        .testTarget(
            name: "WorkflowCoreTests",
            dependencies: ["WorkflowCore"],
            path: "Packages/WorkflowCore/Tests/WorkflowCoreTests"
        ),

        .testTarget(
            name: "WorkflowHostKitTests",
            dependencies: ["WorkflowHostKit", "WorkflowCore"],
            path: "Packages/WorkflowHost/Tests/WorkflowHostKitTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
