// swift-tools-version:5.1
import PackageDescription

let package = Package(
    name: "ping",
    platforms: [
        .macOS(.v10_14),
        .iOS(.v10)
    ],
    products: [
        .library(
            name: "ping",
            targets: ["ping"]
        ),
        .executable(
            name: "pingMacOS",
            targets: ["pingMacOS"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "pingMacOS",
            dependencies: ["ping"],
            path: "Example/MacOS"
        ),
        .target(
            name: "ping",
            dependencies: [],
            path: "Sources/ping"
        ),
        .testTarget(
            name: "pingTests",
            dependencies: ["ping"]
        ),
    ]
)
