// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Haus",
    platforms: [.macOS(.v13), .iOS(.v16), .tvOS(.v16), .watchOS(.v9), .visionOS(.v1)],
    products: [
        .library(name: "Haus", targets: ["Haus"])
    ],
    targets: [
        .target(name: "Haus"),
        .testTarget(name: "HausTests", dependencies: ["Haus"]),
    ]
)
