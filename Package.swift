// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "heykinn-clicks",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "HeykinnClicks",
            path: "Sources/HeykinnClicks",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HeykinnClicksTests",
            dependencies: ["HeykinnClicks"],
            path: "Tests/HeykinnClicksTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
