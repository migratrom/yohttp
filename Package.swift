// swift-tools-version: 6.3

import PackageDescription

// 0.0.1 - alpha
let package = Package(
    name: "yohttp",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "YoHTTP", targets: ["YoHTTP"]),
        .executable(name: "yohttp-example", targets: ["YoHTTPExample"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.3"),
    ],
    targets: [
        .target(
            name: "YoHTTP",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .executableTarget(name: "YoHTTPExample", dependencies: ["YoHTTP"]),
        .testTarget(name: "YoHTTPTests", dependencies: ["YoHTTP"]),
    ],
    swiftLanguageModes: [.v6]
)
