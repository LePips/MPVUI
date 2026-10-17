// swift-tools-version: 6.3

import PackageDescription

// Skip evaluates a relocated manifest for native Android builds. Apple binaries
// and their relative local dependency must be absent from that package graph.
let android = Context.environment["TARGET_OS_ANDROID"] ?? "0" != "0"

let package = Package(
    name: "mpvui-example",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
        .tvOS(.v26)
    ],
    products: [
        .library(name: "MPVUIExample", type: .dynamic, targets: ["MPVUIExample"])
    ],
    dependencies: [
        .package(url: "https://github.com/skiptools/skip.git", from: "1.9.16"),
        .package(url: "https://github.com/skiptools/skip-fuse-ui.git", from: "1.19.0"),
        .package(name: "MPVUI", path: android ? "Packages/android" : "..")
    ] + (android ? [] : [
        .package(url: "https://github.com/LePips/MediaAccessibilityKit", from: "0.2.0")
    ]),
    targets: [
        .target(name: "MPVUIExample", dependencies: [
            .product(name: "SkipFuseUI", package: "skip-fuse-ui")
        ] + (android ? [.product(name: "MPVCoreAndroid", package: "android")] : [
            .product(name: "MPVUI", package: "MPVUI"),
            .product(name: "MediaAccessibilityKit", package: "mediaaccessibilitykit")
        ]), resources: [.copy("Resources/Media")], plugins: [.plugin(
            name: "skipstone",
            package: "skip"
        )])
    ]
)
