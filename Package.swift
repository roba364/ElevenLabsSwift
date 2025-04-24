// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ElevenLabsSDK",
    platforms: [
        .iOS(.v16),
    ],
    products: [
        .library(
            name: "ElevenLabsSDK",
            targets: ["ElevenLabsSDK"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/daltoniam/Starscream.git", from: "4.0.0"),
        .package(url: "https://github.com/devicekit/DeviceKit.git", from: "5.6.0"),
    ],
    targets: [
        .target(
            name: "ElevenLabsSDK",
            dependencies: ["Starscream", "DeviceKit"]
        ),
    ]
)
