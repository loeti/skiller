// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "skiller",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "skiller", targets: ["SkillerCLI"]),
        .library(name: "SkillerKit", targets: ["SkillerKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .target(
            name: "SkillerKit",
            dependencies: [.product(name: "Yams", package: "Yams")]
        ),
        .executableTarget(
            name: "SkillerCLI",
            dependencies: [
                "SkillerKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "SkillerKitTests",
            dependencies: ["SkillerKit"]
        ),
    ]
)
