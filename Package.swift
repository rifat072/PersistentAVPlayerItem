// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PersistentAVPlayerItem",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "PersistentAVPlayerItem", targets: ["PersistentAVPlayerItem"]),
    ],
    targets: [
        .target(name: "PersistentAVPlayerItem"),
        .testTarget(name: "PersistentAVPlayerItemTests", dependencies: ["PersistentAVPlayerItem"]),
    ],
    swiftLanguageModes: [.v6]
)
