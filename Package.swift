// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "wkbrowser",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "WKBCore"),
        .executableTarget(name: "WKBrowser", dependencies: ["WKBCore"]),
        .executableTarget(name: "wkb", dependencies: ["WKBCore"]),
    ]
)
