// swift-tools-version: 6.0
// The Swift runner of the differential fuzzers (../README.md): the parser,
// the stream reader, the canonical form and the formatters of ../../swift.
import PackageDescription

let package = Package(
    name: "HausFuzzRunner",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../../swift")],
    targets: [
        .executableTarget(name: "swift-runner", dependencies: [.product(name: "Haus", package: "swift")])
    ]
)
