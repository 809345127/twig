// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TwigMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TwigMac",
            path: "Sources/TwigMac"
        )
    ]
)
