// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MPVUI",
    platforms: [
        .iOS(.v15),
        .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "MPVUI",
            targets: ["MPVUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/cxfksword/MPVKit", branch: "main"),
    ],
    targets: [
        .target(
            name: "MPVUI",
            dependencies: [
                "MPVKit",
            ]
        ),
        .plugin(
            name: "GenerateCommands",
            capability: .command(
                intent: .custom(
                    verb: "generate-commands",
                    description: "Generates the command enum for MPV commands"
                ),
                permissions: [
                    .writeToPackageDirectory(reason: "To output generated source code"),
                    .allowNetworkConnections(scope: .all(), reason: "To download necessary MPV source files")
                ]
            )
        ),
    ]
)
