// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PewterCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PewterCore", targets: ["PewterCore"]),
    ],
    targets: [
        .target(name: "PewterCore"),
        .testTarget(name: "PewterCoreTests", dependencies: ["PewterCore"]),
    ]
)
