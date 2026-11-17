// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Stahovak",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Stahovak", path: "Sources/Stahovak")
    ]
)
