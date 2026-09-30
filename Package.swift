// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BetterClaude",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CoworkKit", targets: ["CoworkKit"]),
        .executable(name: "cowork", targets: ["cowork"]),
        .executable(name: "BetterClaude", targets: ["BetterClaude"]),
        .executable(name: "bc-fixture", targets: ["bc-fixture"]),
        .executable(name: "bc-recall", targets: ["bc-recall"]),
    ],
    targets: [
        .target(name: "CoworkKit"),
        .executableTarget(name: "cowork", dependencies: ["CoworkKit"]),
        // The MCP server Claude talks to; shipped inside the app bundle.
        .executableTarget(name: "bc-recall", dependencies: ["CoworkKit"]),
        .executableTarget(
            name: "BetterClaude",
            dependencies: ["CoworkKit"],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        // A synthetic Mac for tests and screenshots. Never linked into the shipped app.
        .target(name: "CoworkFixtures", dependencies: ["CoworkKit"]),
        .executableTarget(name: "bc-fixture", dependencies: ["CoworkFixtures"]),
        // Corpus: the shapes of real Claude Code and Codex files, read from the source tree.
        .testTarget(name: "CoworkKitTests", dependencies: ["CoworkKit", "CoworkFixtures"], exclude: ["Corpus"]),
    ]
)
