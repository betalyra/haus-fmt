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
        // The examples (`swift run quickstart`, `swift run order`); expected.txt is the
        // output they share with the other bindings' examples.
        .executableTarget(
            name: "quickstart", dependencies: ["Haus"], path: "Examples/quickstart", exclude: ["expected.txt"]),
        .executableTarget(name: "order", dependencies: ["Haus"], path: "Examples/order", exclude: ["expected.txt"]),
    ]
)
