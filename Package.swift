// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UAI",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Self-update, the macOS equivalent of the Windows app's electron-updater.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "UAI",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/UAI",
            resources: [.process("Resources")]
        )
    ]
)
