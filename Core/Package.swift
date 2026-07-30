// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SmartListCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SmartListCore", targets: ["SmartListCore"]),
    ],
    targets: [
        .target(name: "SmartListCore"),
        .testTarget(name: "SmartListCoreTests", dependencies: ["SmartListCore"]),
    ]
)
