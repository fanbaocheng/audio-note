// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioNote",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AudioNote", targets: ["AudioNoteApp"]),
        .executable(name: "audio-note", targets: ["AudioNoteCLI"]),
        .library(name: "AudioNoteCore", targets: ["AudioNoteCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        // 业务/引擎层：GUI 和 CLI 共享
        .target(
            name: "AudioNoteCore",
            path: "Sources/AudioNoteCore",
            resources: [
                .copy("../../scripts"),
                .copy("../../vendor")
            ]
        ),
        // GUI App
        .executableTarget(
            name: "AudioNoteApp",
            dependencies: ["AudioNoteCore"],
            path: "Sources/AudioNoteApp"
        ),
        // CLI 入口
        .executableTarget(
            name: "AudioNoteCLI",
            dependencies: [
                "AudioNoteCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/AudioNoteCLI"
        ),
        .testTarget(
            name: "AudioNoteTests",
            dependencies: ["AudioNoteCore"],
            path: "Tests"
        )
    ]
)
