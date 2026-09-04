// swift-tools-version: 6.3

import PackageDescription
import CompilerPluginSupport

// 0.0.1 - alpha
let package = Package(
    name: "yohttp",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "YoHTTP", targets: ["YoHTTP"]),
        .executable(name: "yohttp-example", targets: ["YoHTTPExample"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.3"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.35.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.1"),
    ],
    targets: [
        .target(
            name: "YoHTTP",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                "YoHTTPMacros",
            ]
        ),
        .macro(
            name: "YoHTTPMacros",
            dependencies: [
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .executableTarget(name: "YoHTTPExample", dependencies: ["YoHTTP"]),
        .testTarget(
            name: "YoHTTPTests",
            dependencies: [
                "YoHTTP",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            linkerSettings: [
                .unsafeFlags(
                    ["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"],
                    .when(platforms: [.macOS])
                ),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
