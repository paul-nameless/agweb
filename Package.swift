// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "agweb",
    platforms: [.macOS("15.4")],
    targets: [
        .target(name: "AgwebCore"),
        // WebKit's private security key client (SecurityKeyWebKit.swift), declared in Objective-C.
        .target(name: "WebAuthnSPI", linkerSettings: [.linkedFramework("WebKit")]),
        .executableTarget(name: "AgwebApp", dependencies: ["AgwebCore", "WebAuthnSPI"]),
        .executableTarget(name: "agweb", dependencies: ["AgwebCore"]),
        .testTarget(name: "AgwebCoreTests", dependencies: ["AgwebCore"]),
    ]
)
