// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "agweb",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "AgwebCore"),
        .executableTarget(name: "AgwebApp", dependencies: ["AgwebCore"]),
        .executableTarget(name: "agweb", dependencies: ["AgwebCore"]),
        .testTarget(name: "AgwebCoreTests", dependencies: ["AgwebCore"]),
    ]
)
