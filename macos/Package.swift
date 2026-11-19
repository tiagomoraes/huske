// swift-tools-version: 6.0
// Native macOS app for huske. The Python package in ../huske stays the
// engine; this app is a supervisor + UI over its control socket.
//
// `HuskeSync` is the phone ↔ Mac sync library (specs/002-phone-sync). It is
// the one target that also builds for iOS: the iPhone app in ../ios depends on
// it as a local package product. HuskeKit and the Huske app are macOS-only
// (AppKit); the iOS platform entry only matters for HuskeSync.
import PackageDescription

let package = Package(
    name: "Huske",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "HuskeSync", targets: ["HuskeSync"]),
        .executable(name: "Huske", targets: ["Huske"]),
    ],
    targets: [
        .target(
            name: "HuskeSync",
            path: "Sources/HuskeSync"
        ),
        .target(
            name: "HuskeKit",
            dependencies: ["HuskeSync"],
            path: "Sources/HuskeKit"
        ),
        .executableTarget(
            name: "Huske",
            dependencies: ["HuskeKit", "HuskeSync"],
            path: "Sources/Huske",
            resources: [
                .copy("Resources/Fonts")
            ]
        ),
        .testTarget(
            name: "HuskeKitTests",
            dependencies: ["HuskeKit", "HuskeSync"],
            path: "Tests/HuskeKitTests"
        ),
        .testTarget(
            name: "HuskeSyncTests",
            dependencies: ["HuskeSync"],
            path: "Tests/HuskeSyncTests"
        ),
    ]
)
