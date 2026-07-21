// swift-tools-version: 6.0
// Native macOS app for huske. The Python package in ../huske stays the
// engine; this app is a supervisor + UI over its control socket.
import PackageDescription

let package = Package(
    name: "Huske",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "HuskeKit",
            path: "Sources/HuskeKit"
        ),
        .executableTarget(
            name: "Huske",
            dependencies: ["HuskeKit"],
            path: "Sources/Huske",
            resources: [
                .copy("Resources/Fonts")
            ]
        ),
        .testTarget(
            name: "HuskeKitTests",
            dependencies: ["HuskeKit"],
            path: "Tests/HuskeKitTests"
        ),
    ]
)
