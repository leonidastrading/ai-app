// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UAI",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "UAI",
            path: "Sources/UAI"
        )
    ]
)
