// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "awdl-lan-helper",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "awdl-lan-helper", path: "Sources/awdl-lan-helper")
    ]
)
