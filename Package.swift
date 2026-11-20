// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DroidDrop",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DroidDropCore", targets: ["DroidDropCore"]),
        .executable(name: "DroidDrop", targets: ["DroidDrop"])
    ],
    targets: [
        .target(
            name: "DroidDropCore",
            path: "Sources/DroidDropCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "DroidDrop",
            dependencies: ["DroidDropCore"],
            path: "Sources/DroidDrop",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DroidDropCoreTests",
            dependencies: ["DroidDropCore"],
            path: "Tests/DroidDropCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
