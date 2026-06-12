// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AerialRotateApp",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "AerialRotateApp",
            path: "Sources/AerialRotateApp",
            exclude: ["Resources"],   // Info.plist is assembled into the bundle by build.sh, not a SwiftPM resource
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
