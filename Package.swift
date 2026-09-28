// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QWebSyphon",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.4"),
        .package(url: "https://github.com/orchetect/swift-osc", from: "3.1.0"),
    ],
    targets: [
        .binaryTarget(
            name: "Syphon",
            path: "./third_party/Syphon.xcframework"
        ),
        // Pure logic (Foundation + CoreGraphics only, no Syphon/Metal/AppKit): testable directly
        // with `swift test`, unlike the executable target below (unsafeFlags + top-level
        // main.swift code make it unsuitable for `@testable import`).
        .target(
            name: "QWebSyphonCore"
        ),
        .executableTarget(
            name: "QWebSyphon",
            dependencies: [
                "Syphon", "QWebSyphonCore", .product(name: "SQLite", package: "sqlite.swift"),
                .product(name: "SwiftOSC", package: "swift-osc"),
            ],
            swiftSettings: [
                // Again. More hacks to use Syphon framework outside of the usual XCode environment. Ugh.
                .unsafeFlags([
                    "-I",
                    "./third_party/Syphon.xcframework/macos-arm64_x86_64/Syphon.framework/Headers",
                ])
            ]
        ),
        .testTarget(
            name: "QWebSyphonCoreTests",
            dependencies: ["QWebSyphonCore"]
        ),
    ]
)
