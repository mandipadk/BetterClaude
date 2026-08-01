// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BetterClaude",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CoworkKit", targets: ["CoworkKit"]),
        .executable(name: "cowork", targets: ["cowork"]),
        .executable(name: "BetterClaude", targets: ["BetterClaude"]),
    ],
    targets: [
        .target(name: "CoworkKit"),
        .executableTarget(name: "cowork", dependencies: ["CoworkKit"]),
        .executableTarget(
            name: "BetterClaude",
            dependencies: ["CoworkKit"],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        .testTarget(name: "CoworkKitTests", dependencies: ["CoworkKit"]),
    ]
)
