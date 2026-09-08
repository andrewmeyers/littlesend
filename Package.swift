// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LittleSend",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LittleSend", targets: ["LittleSend"]),
        .library(name: "LittleSendCore", targets: ["LittleSendCore"]),
    ],
    targets: [
        .target(
            name: "LittleSendCore",
            resources: [.copy("Resources/Readability.js")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "LittleSend",
            dependencies: ["LittleSendCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LittleSendCoreTests",
            dependencies: ["LittleSendCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
