import Foundation

struct ConsumerTestRecord: Codable {

    let key: String
    let artifactDigests: [String: String]
    let checks: [String]
    let unavailableRuntimeChecks: [String]
    let complete: Bool
}

struct ConsumerTests {

    struct Simulator {

        let id: String
        let runtime: String
        let state: String
    }

    static let exampleBuildState: Set<String> = [
        ".build",
        ".gradle",
        ".kotlin",
        ".swiftpm",
        ".skip",
        ".idea",
        "build",
        "xcuserdata",
        ".DS_Store",
        "local.properties",
        "keystore.properties"
    ]

    let graph: BuildGraph

    static func copyExample(_ source: URL, to destination: URL) throws {
        try mkdir(destination)

        for input in try files(source, pruning: exampleBuildState) {
            let relative = String(input.path.dropFirst(source.path.count + 1))
            let output = destination.appendingPathComponent(relative)
            let values = try input.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])

            if values.isDirectory == true && values.isSymbolicLink != true {
                try mkdir(output)
            } else {
                try fm.copyItem(at: input, to: output)
            }
        }
    }

    static func validateArchive(_ archive: URL, slice: Slice) throws {
        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: archive.appendingPathComponent("Info.plist")),
            format: nil
        )

        guard let properties = (info as? [String: Any])?["ApplicationProperties"] as? [String: Any],
              let path = properties["ApplicationPath"] as? String
        else { throw BuildError("Missing application path in \(archive.path)") }

        let app = try contained(archive.appendingPathComponent("Products"), path)
        let frameworks = slice.platform == "macos" ? "Contents/Frameworks" : "Frameworks"
        try MachO.validate(app.appendingPathComponent(frameworks + "/Libmpv.framework/Libmpv"), slice: slice)
    }

    static func validateConsoleSession(_ properties: [String: Any], user: String) throws {
        let sessions = properties["IOConsoleUsers"] as? [[String: Any]] ?? []

        let session = sessions.first {
            $0["kCGSSessionUserNameKey"] as? String == user
                && $0["kCGSSessionOnConsoleKey"] as? Bool == true
                && $0["kCGSessionLoginDoneKey"] as? Bool == true
        }

        try require(
            session != nil
                && properties["IOConsoleLocked"] as? Bool != true
                && session?["CGSSessionScreenIsLocked"] as? Bool != true,
            "Apple playback validation requires an unlocked desktop session for \(user). "
                + "Unlock the Mac and keep it unlocked until validation finishes."
        )
    }

    static func selectSimulators(_ inventory: [Simulator], environment: [String: String]) throws -> [Simulator] {
        var selected = inventory

        for (platform, variable) in [("iOS", "MPVUI_IOS_SIMULATOR"), ("tvOS", "MPVUI_TVOS_SIMULATOR")] {
            guard let id = environment[variable] else { continue }

            let prefix = "." + platform + "-"

            try require(
                inventory.contains { $0.id == id && $0.runtime.contains(prefix) },
                "\(variable) must identify an available \(platform) simulator"
            )

            selected.removeAll { $0.runtime.contains(prefix) && $0.id != id }
        }

        return selected
    }

    func testKey(_ index: ArtifactIndex, nativeOnly: Bool) throws -> String {
        struct Identity: Encodable {

            let artifacts: ArtifactIndex
            let sources: [String: String]
            let tests: [String: String]
            let manifest: String
            let examples: [String: String]
            let fixtureGenerators: [String: String]
            let verifier: String
            let toolchain: ToolchainLock
            let nativeOnly: Bool
            let destinations: [String]
        }

        let destinations = nativeOnly ? [] : try simulators().map { $0.runtime + "/" + $0.id }.sorted()

        return try fingerprint(Identity(
            artifacts: index,
            sources: tree(graph.root.appendingPathComponent("Sources")),
            tests: tree(graph.root.appendingPathComponent("Tests")),
            manifest: digest(graph.root.appendingPathComponent("Package.swift")),
            examples: tree(graph.root.appendingPathComponent("Example"), pruning: Self.exampleBuildState),
            fixtureGenerators: tree(graph.root.appendingPathComponent("Build/Tests")).filter { $0.key.hasSuffix(".py") },
            verifier: digest(graph.codeRoot.appendingPathComponent("ConsumerTests.swift")),
            toolchain: graph.native.apple.toolchain,
            nativeOnly: nativeOnly,
            destinations: destinations
        ))
    }

    func materialize(_ candidate: URL, index: ArtifactIndex) throws -> [String: URL] {
        var paths: [String: URL] = [:]

        for artifact in index.products {
            let archive = try contained(candidate, artifact.archive)
            try require(digest(archive) == artifact.sha256, "Candidate archive changed: \(artifact.target)")

            let extracted = try graph.store.node(stage: "test-inputs", name: artifact.target, key: artifact.sha256) { output in
                try Archive.extract(archive, to: output.appendingPathComponent("content"), runner: graph.runner)
                return ["sha256", "safe-extraction"]
            }.appendingPathComponent("content/" + artifact.framework + ".xcframework")
            try ReleaseManager(graph: graph).verifyEmbeddedBuildRecord(extracted.deletingLastPathComponent(), index: index)
            paths[artifact.target] = extracted
        }

        return paths
    }

    func stagePackage(_ paths: [String: URL], index: ArtifactIndex, key: String, remote: Bool = false) throws -> URL {
        let stage = try graph.store.path("work/tests/\(key)/\(remote ? "remote-package" : "package")")
        try remove(stage)
        try mkdir(stage)

        for name in ["Sources", "Tests", "Example", "Build/Tests"] {
            try mkdir(stage.appendingPathComponent(name).deletingLastPathComponent())

            if name == "Example" {
                try Self.copyExample(graph.root.appendingPathComponent(name), to: stage.appendingPathComponent(name))
                continue
            }

            try fm.copyItem(
                at: graph.root.appendingPathComponent(name),
                to: stage.appendingPathComponent(name)
            )
        }

        let original = try String(contentsOf: graph.root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let links = remote ? nil : try Generator.localLinks(paths, package: stage, identity: fingerprint(index))
        let manifest = try Generator.manifest(original, index: index, local: links, packageRoot: stage)
        try put(manifest, stage.appendingPathComponent("Package.swift"))
        try Generator.evaluate(Data(manifest.utf8), runner: graph.runner)

        let evaluated = try graph.runner.run("/usr/bin/swift", ["package", "--package-path", stage.path, "dump-package"])

        try require(
            evaluated.contains(remote ? index.products.first { $0.target == "Libmpv-GPL" }!.url : relativePath(
                from: stage,
                to: links!["Libmpv-GPL"]!
            )),
            "SwiftPM did not resolve the selected candidate target"
        )

        return stage
    }

    func validateRemote(_ index: ArtifactIndex) throws {
        try require(!graph.inputs.offline, "Fresh remote consumer validation requires network access")
        _ = try graph.runner.doctor(graph.native.apple.toolchain)

        let stage = try stagePackage([:], index: index, key: UUID().uuidString, remote: true)

        // Both workspace and SwiftPM download cache start empty; maintainer caches cannot hide a bad URL.
        try graph.runner.run(
            "/usr/bin/swift",
            ["package", "--package-path", stage.path, "--cache-path", stage.appendingPathComponent(".swiftpm-cache").path, "resolve"]
        )

        _ = try wrapperChecks(stage)
    }

    func run(_ candidate: URL, nativeOnly: Bool = false) throws -> URL {
        _ = try graph.runner.doctor(graph.native.apple.toolchain)

        let index = try read(ArtifactIndex.self, candidate.appendingPathComponent("Artifacts.lock.json"))
        try Generator.validate(index, native: graph.native, release: !nativeOnly)

        let key = try testKey(index, nativeOnly: nativeOnly)
        let lock = try FileLock(graph.store.path("locks/test-\(key).lock"))
        defer { withExtendedLifetime(lock) {} }

        let paths = try materialize(candidate, index: index)
        var checks: [String] = []
        var unavailable: [String] = []
        let attempt = key + "-" + UUID().uuidString
        let work = try graph.store.path("work/tests/\(attempt)/native")
        try mkdir(work)

        for slice in index.products[0].slices {
            // Every architecture gets a native import/link check; simulator execution uses the host architecture.
            for arch in slice.architectures {
                try nativeConsumer(slice: slice, arch: arch, paths: paths, work: work)
                checks.append("native-import-link/\(slice.id)/\(arch)")
                checks.append("native-symbol-isolation/\(slice.id)/\(arch)")
            }
        }

        if !nativeOnly {
            // The staged test runner generates and verifies its own media;
            // source-tree fixtures and maintainer caches are not prerequisites.
            let stage = try stagePackage(paths, index: index, key: attempt)
            checks += try wrapperChecks(stage)

            let devices = try simulators()

            if let device = devices.first(where: { $0.runtime.contains(".xrOS-") || $0.runtime.contains(".visionOS-") }) {
                if device.state != "Booted" {
                    try graph.runner.run("/usr/bin/xcrun", ["simctl", "boot", device.id])
                }

                try graph.runner.run("/usr/bin/xcrun", ["simctl", "bootstatus", device.id, "-b"])

                let binary = work.appendingPathComponent("smoke-xrsimulator-arm64")
                try graph.runner.run("/usr/bin/xcrun", ["simctl", "spawn", device.id, binary.path])
                checks.append("visionos-simulator-smoke")
            } else {
                unavailable.append("visionOS simulator runtime is not installed; device/simulator import and link checks passed")
            }
        }

        // Rehash the exact input archives after tests. A stale passed flag cannot authorize changed bytes.
        for artifact in index.products {
            try require(
                digest(candidate.appendingPathComponent(artifact.archive)) == artifact.sha256,
                "Candidate changed during tests"
            )
        }

        try require(
            testKey(index, nativeOnly: nativeOnly) == key,
            "Swift sources, fixtures, or test configuration changed during validation"
        )

        let record = ConsumerTestRecord(
            key: key,
            artifactDigests: Dictionary(uniqueKeysWithValues: index.products.map { ($0.archive, $0.sha256) }),
            checks: checks,
            unavailableRuntimeChecks: unavailable,
            complete: true
        )

        let receipt = try graph.store.path("test-results/\(key).json")
        try write(record, receipt)

        return receipt
    }

    func wrapperChecks(_ stage: URL) throws -> [String] {
        var checks: [String] = []
        let console = try graph.runner.run("/usr/sbin/ioreg", ["-l", "-a", "-n", "Root", "-d1"])
        let properties = try PropertyListSerialization.propertyList(from: Data(console.utf8), format: nil)
        try Self.validateConsoleSession(properties as? [String: Any] ?? [:], user: NSUserName())

        // The runner keeps the display awake for AVFoundation readback.
        try graph.runner.run("python3", [stage.appendingPathComponent("Build/Tests/run_swift_tests.py").path])
        checks.append("macos-swift-tests")
        try graph.runner.run("/usr/bin/swift", ["build", "--package-path", stage.path, "-c", "release"])
        checks.append("macos-release-package")

        let devices = try simulators()

        for (platform, prefix) in [("iOS Simulator", "iOS"), ("tvOS Simulator", "tvOS")] {
            guard let device = devices.first(where: { $0.runtime.contains("." + prefix + "-") })
            else { throw BuildError("Missing required \(prefix) simulator runtime") }

            // The product schemes do not include tests in a multi-product package.
            var testTarget = ["-scheme", "MPVUI-Package"]

            if prefix == "iOS" {
                // Rotation and presentation tests require an app-owned window scene.
                let host = stage.appendingPathComponent(".build/ios-test-host")

                try graph.runner.run(
                    "python3",
                    [
                        stage.appendingPathComponent("Build/Tests/generate_device_test_project.py").path,
                        "--repository",
                        stage.path,
                        "--output",
                        host.path,
                    ],
                    env: ["USER": NSUserName()]
                )

                try graph.runner.run(
                    "python3",
                    [
                        stage.appendingPathComponent("Build/Tests/prepare_test_media.py").path,
                        "--output",
                        host.appendingPathComponent("GeneratedMedia").path,
                    ]
                )

                testTarget = [
                    "-project",
                    host.appendingPathComponent("MPVUIRegressionTests.xcodeproj").path,
                    "-scheme",
                    "MPVUIRegressionTests",
                ]
            }

            try graph.runner.run(
                "/usr/bin/caffeinate",
                ["-disu", "/usr/bin/xcodebuild"] + testTarget + [
                    "-parallel-testing-enabled",
                    "NO",
                    "-destination",
                    "platform=\(platform),id=\(device.id)",
                    "-derivedDataPath",
                    stage.appendingPathComponent(".build/" + prefix).path,
                    "test",
                    "CODE_SIGNING_ALLOWED=NO"
                ],
                cwd: stage
            )

            checks.append(prefix.lowercased() + "-simulator-swift-tests")
        }

        let project = stage.appendingPathComponent("Example/Darwin/MPVUIExample.xcodeproj")

        for configuration in ["Debug", "Release"] {
            for (scheme, destination) in [
                ("macOS", "generic/platform=macOS"),
                ("iOS", "generic/platform=iOS Simulator"),
                ("tvOS", "generic/platform=tvOS Simulator")
            ] {
                try graph.runner.run(
                    "/usr/bin/xcodebuild",
                    [
                        "-project",
                        project.path,
                        "-scheme",
                        "MPVUI App",
                        "-configuration",
                        configuration,
                        "-destination",
                        destination,
                        "-derivedDataPath",
                        stage.appendingPathComponent(".build/example-" + scheme).path,
                        "build",
                        "CODE_SIGNING_ALLOWED=NO",
                        "-skipPackagePluginValidation"
                    ],
                    cwd: stage,
                    env: ["SKIP_DYNAMIC_LIBRARIES": "1", "SKIP_ACTION": "none"]
                )

                checks.append("example/\(scheme)/\(configuration)")
            }
        }

        // Exercise deployment metadata in actual consumer archives as well as simulator builds.
        for (scheme, destination) in [
            ("macOS", "generic/platform=macOS"),
            ("iOS", "generic/platform=iOS"),
            ("tvOS", "generic/platform=tvOS")
        ] {
            let archive = stage.appendingPathComponent(".build/archives/" + scheme + ".xcarchive")

            try graph.runner.run(
                "/usr/bin/xcodebuild",
                [
                    "-project",
                    project.path,
                    "-scheme",
                    "MPVUI App",
                    "-configuration",
                    "Release",
                    "-destination",
                    destination,
                    "-derivedDataPath",
                    stage.appendingPathComponent(".build/example-" + scheme).path,
                    "-archivePath",
                    archive.path,
                    "archive",
                    "CODE_SIGNING_ALLOWED=NO",
                    "-skipPackagePluginValidation"
                ],
                cwd: stage,
                env: ["SKIP_DYNAMIC_LIBRARIES": "1", "SKIP_ACTION": "none"]
            )

            checks.append("example/\(scheme)/archive")

            guard let slice = graph.native.apple.slices.first(where: { $0.id == scheme.lowercased() })
            else { throw BuildError("Missing native slice for \(scheme) archive") }

            try Self.validateArchive(archive, slice: slice)
            checks.append("example/\(scheme)/archive-native-architectures")
        }

        return checks
    }

    func simulators() throws -> [Simulator] {
        let json = try graph.runner.run("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "--json"])

        guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let devices = object["devices"] as? [String: [[String: Any]]] else { throw BuildError("Invalid simulator inventory") }

        let inventory: [Simulator] = devices.keys.sorted().reversed().flatMap { runtime in devices[runtime]!.compactMap { value in
            guard let id = value["udid"] as? String, let state = value["state"] as? String else { return nil }

            return Simulator(id: id, runtime: runtime, state: state)
        } }

        return try Self.selectSimulators(inventory, environment: ProcessInfo.processInfo.environment)
    }

    func nativeConsumer(slice: Slice, arch: String, paths: [String: URL], work: URL) throws {
        let source = work.appendingPathComponent("smoke-\(slice.id)-\(arch).m")
        let imports = ProductDefinition.all.map { "@import \($0.framework);" }.joined(separator: "\n")

        try put(
            imports +
                // Simulate a host that already exports an incompatible FFmpeg.
                // mpv must use its own avcodec_version, while the host keeps 0.
                "\nunsigned avcodec_version(void) { return 0; }\n" +
                """
                int main(void) { mpv_handle *h = mpv_create(); if (!h) return 2; mpv_set_option_string(h, \"vo\", \"null\"); \
                mpv_set_option_string(h, \"ao\", \"null\"); int rc = mpv_initialize(h); if (rc < 0) { mpv_destroy(h); return 3; } \
                mpv_terminate_destroy(h); return avcodec_version() != 0; }\n
                """,
            source
        )

        try require(paths.count == 1 && paths["Libmpv-GPL"] != nil, "Consumer must link only the combined native artifact")

        var libraries: [String] = []
        var frameworks: [String] = []

        for name in paths.keys.sorted() {
            let xcf = paths[name]!
            let selected = try XCFLibrary.select(XCFLibrary.all(xcf), slice: slice, arch: arch)
            let binary = selected.binary(xcf)
            libraries.append(binary.path)

            if selected.libraryPath.hasSuffix(".framework") {
                frameworks += [
                    "-F",
                    binary.deletingLastPathComponent().deletingLastPathComponent().path
                ]
            }
        }

        var args = try NativeLibrary.linkArguments(slice: slice, arch: arch, runner: graph.runner) + [
            "-fmodules",
            "-fmodules-cache-path=" + work.appendingPathComponent("modules").path,
            source.path
        ] + frameworks + libraries

        // The native executable lives outside an app bundle during validation.
        // SwiftPM/Xcode embeds this framework in the consumer app normally.
        for index in stride(from: 1, to: frameworks.count, by: 2) {
            args += ["-Xlinker", "-rpath", "-Xlinker", frameworks[index]]
        }

        args += ["-o", work.appendingPathComponent("smoke-\(slice.id)-\(arch)").path]
        try graph.runner.run("/usr/bin/clang", args)
        #if arch(arm64)
        let hostArchitecture = "arm64"
        #else
        let hostArchitecture = "x86_64"
        #endif
        if slice.id == "macos", arch == hostArchitecture {
            try graph.runner.run(work.appendingPathComponent("smoke-\(slice.id)-\(arch)").path)
        }
    }
}
