// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Dynotch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Dynotch", targets: ["Dynotch"]),
        .executable(name: "DynotchCommand", targets: ["DynotchCommand"])
    ],
    targets: [
        .target(
            name: "DynotchShared",
            path: "Sources/DynotchShared"
        ),
        .executableTarget(
            name: "Dynotch",
            dependencies: ["DynotchShared"],
            path: "Sources/Dynotch"
        ),
        // The `dynotch` command. macOS gives a program's permissions to its signed identity, and this
        // runs what it's told to, so it stays a binary of its own that the app never links.
        .executableTarget(
            name: "DynotchCommand",
            dependencies: ["DynotchShared"],
            path: "Sources/DynotchCommand"
        ),
        .testTarget(
            name: "DynotchTests",
            dependencies: ["Dynotch", "DynotchCommand", "DynotchShared"],
            path: "Tests/DynotchTests"
        )
    ]
)
