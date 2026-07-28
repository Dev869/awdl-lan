// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "awdl-lan-helper",
    // AWDL over Network.framework is 10.15+, and nothing here needs newer.
    platforms: [.macOS(.v10_15)],
    targets: [
        .executableTarget(name: "awdl-lan-helper", path: "Sources/awdl-lan-helper")
    ]
)
