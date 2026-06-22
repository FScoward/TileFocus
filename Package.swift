// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TileFocus",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/soffes/HotKey", from: "0.2.0")
    ],
    targets: [
        .executableTarget(
            name: "TileFocus",
            dependencies: [
                .product(name: "HotKey", package: "HotKey")
            ],
            path: "Sources/TileFocus"
        ),
        .testTarget(
            name: "TileFocusTests",
            dependencies: ["TileFocus"],
            path: "Tests/TileFocusTests"
        )
    ]
)
