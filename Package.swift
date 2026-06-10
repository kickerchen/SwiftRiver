// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftRiver",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "SwiftRiver",
            targets: ["SwiftRiver"]
        ),
    ],
    targets: [
        .target(
            name: "SwiftRiver",
            path: "Sources"
        ),
        .testTarget(
            name: "SwiftRiverTests",
            dependencies: ["SwiftRiver"],
            path: "Tests"
        ),
    ]
)