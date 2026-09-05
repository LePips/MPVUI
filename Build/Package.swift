// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "MPVBuild",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "mpvbuild", targets: ["mpvbuild"])],
    targets: [
        .target(name: "MPVBuildCore"),
        .executableTarget(name: "mpvbuild", dependencies: ["MPVBuildCore"]),
        .testTarget(name: "MPVBuildCoreTests", dependencies: ["MPVBuildCore"]),
    ],
    swiftLanguageModes: [.v6]
)
