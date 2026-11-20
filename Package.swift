// swift-tools-version: 6.0
// The Swift package of haus for SwiftPM users, who can only depend on a
// repository whose manifest is at its root. The sources, tests and the
// development manifest are in swift/ (see swift/README.md).
import PackageDescription

let package = Package(
    name: "Haus",
    platforms: [.macOS(.v13), .iOS(.v16), .tvOS(.v16), .watchOS(.v9), .visionOS(.v1)],
    products: [
        .library(name: "Haus", targets: ["Haus"])
    ],
    targets: [
        .target(name: "Haus", path: "swift/Sources/Haus")
    ]
)
