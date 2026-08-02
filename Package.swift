// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "skill-tool",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "skill-tool", targets: ["SkillToolCLI"]),
        .library(name: "SkillToolKit", targets: ["SkillToolKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .target(
            name: "SkillToolKit",
            dependencies: [.product(name: "Yams", package: "Yams")]
        ),
        .executableTarget(
            name: "SkillToolCLI",
            dependencies: [
                "SkillToolKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "SkillToolKitTests",
            dependencies: ["SkillToolKit"]
        ),
    ]
)
