// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoreSDR",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CoreSDR", targets: ["CoreSDR"]),
    ],
    targets: [
        .target(
            name: "CoreSDR",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "coresdr-demo",
            dependencies: ["CoreSDR"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CoreSDRTests",
            dependencies: ["CoreSDR"],
            resources: [.process("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CoreSDRIntegrationTests",
            dependencies: ["CoreSDR"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
