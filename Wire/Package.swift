// swift-tools-version: 6.1
//
// ClaudeWMWire — the vocabulary Claude WM and its iOS client both speak.
//
// ## Why this exists at all
//
// The Mac app and the phone are one product, and they have to agree on a wire
// format exactly. Duplicating the types is the precedent CLAUDE.md sets for
// `GitHubIssue`, but that precedent does not transfer: those two copies are
// genuinely different things (a Swift 6 SPM value type, and a Swift 5 decoder
// for `gh`'s JSON inside a SwiftData target). These would be the same type
// written twice, and the drift would show up as a decode failure on a phone —
// the hardest place to attach a debugger.
//
// ## Why it is NOT the package in the repo root
//
// That one is WorkflowHost, a separate product. CLAUDE.md's rule — never make
// the SPM package a dependency of the Xcode project, or the reverse — is about
// keeping those two apart, and it still holds. This package exists on the app's
// side of that wall:
//
//   * `Wire/` is deliberately outside `Packages/`, which belongs to the host.
//   * Nothing here may depend on WorkflowCore, and nothing in `Packages/` may
//     depend on this. If those ever need to meet, the answer is to copy a type,
//     not to draw an edge between the two products.
//   * The macOS and iOS targets of `workflow-manager.xcodeproj` are the only
//     permitted consumers.
//
// ## Keep it boring
//
// No dependencies, no I/O, no `@MainActor`, no SwiftData. Pure `Sendable` value
// types and their codecs, so the format can be exercised on its own the way
// `WorkflowTasksFile` and `MarkdownBlock` already are.

import PackageDescription

let package = Package(
    name: "ClaudeWMWire",
    // Below the app's own floor on purpose: the phone ships to older iOS than
    // the Mac app requires of macOS, and nothing here needs a recent SDK.
    platforms: [
        .macOS(.v15),
        .iOS(.v17),
    ],
    products: [
        .library(name: "ClaudeWMWire", targets: ["ClaudeWMWire"]),
    ],
    targets: [
        .target(
            name: "ClaudeWMWire",
            path: "Sources/ClaudeWMWire"
        ),
        .testTarget(
            name: "ClaudeWMWireTests",
            dependencies: ["ClaudeWMWire"],
            path: "Tests/ClaudeWMWireTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
