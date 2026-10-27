// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Dynotch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Dynotch", targets: ["Dynotch"])
    ],
    targets: [
        .executableTarget(
            name: "Dynotch",
            path: "Sources/Dynotch"
        )
    ]
)
