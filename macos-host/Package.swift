// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacHost",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MacHost", targets: ["MacHost"])
    ],
    targets: [
        // Framework WebRTC con supporto nativo per macOS (Apple Silicon arm64 e Intel x86_64)
        .binaryTarget(
            name: "WebRTC",
            path: "Frameworks/WebRTC.xcframework"
        ),
        .executableTarget(
            name: "MacHost",
            dependencies: [
                "WebRTC"
            ],
            path: "Sources"
        )
    ]
)
