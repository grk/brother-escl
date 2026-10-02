// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "brother-escl",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "brother-escl", path: "Sources/brother-escl")
    ]
)
