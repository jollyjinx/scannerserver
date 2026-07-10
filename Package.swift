// swift-tools-version: 6.3

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .unsafeFlags(["-strict-concurrency=complete"]),
]

let package = Package(
    name: "ScannerServer",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "scannerserver", targets: ["scannerserver"]),
        .library(name: "ScannerServerCore", targets: ["ScannerServerCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/jollyjinx/JLog.git", from: "0.0.9"),
    ],
    targets: [
        .executableTarget(
            name: "scannerserver",
            dependencies: [
                "ScannerServerCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "JLog", package: "JLog"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ScannerServerCore",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "JLog", package: "JLog"),
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ScannerServerCoreTests",
            dependencies: ["ScannerServerCore"],
            path: "tests/ScannerServerCoreTests",
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
