// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "mcdirect-helper",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "mcdirect-helper", path: "Sources/mcdirect-helper")
    ]
)
