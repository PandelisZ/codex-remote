// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexRemote",
    // macOS 15 is the floor: it is what the modern `Tab` API and several SwiftUI conveniences
// need. Liquid Glass is applied at run time where macOS 26 provides it, with a standard
// material below that, so a 15 or earlier-26 Mac still gets a native-looking app.
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CodexRemoteKit", targets: ["CodexRemoteKit"]),
        .executable(name: "CodexRemoteApp", targets: ["CodexRemoteApp"]),
        .executable(name: "codex-remote", targets: ["CodexRemoteCLI"]),
    ],
    targets: [
        .target(
            name: "CodexRemoteKit",
            path: "Sources/CodexRemoteKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "CodexRemoteApp",
            dependencies: ["CodexRemoteKit"],
            path: "Sources/CodexRemoteApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "CodexRemoteCLI",
            dependencies: ["CodexRemoteKit"],
            path: "Sources/CodexRemoteCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CodexRemoteKitTests",
            dependencies: ["CodexRemoteKit"],
            path: "Tests/CodexRemoteKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
