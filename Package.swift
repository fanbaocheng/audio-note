// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioNote",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AudioNote", targets: ["AudioNote"])
    ],
    targets: [
        .executableTarget(
            name: "AudioNote",
            path: "Sources",
            resources: [
                .copy("../scripts"),
                .copy("../vendor")
            ]
        ),
        .testTarget(
            name: "AudioNoteTests",
            dependencies: ["AudioNote"],
            path: "Tests"
        )
    ]
)
