import Foundation

struct ConsumerTestRecord: Codable {
    let schemaVersion: Int
    let key: String
    let artifactDigests: [String: String]
    let checks: [String]
    let unavailableRuntimeChecks: [String]
    let complete: Bool
}

struct ConsumerTests {
    let graph: BuildGraph
    func testKey(_ index: ArtifactIndex, nativeOnly: Bool) throws -> String {
        struct Identity: Encodable { let artifacts: ArtifactIndex
            let sources: [String: String]
            let tests: [String: String]
            let manifest: String
            let examples: [String: String]
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
            examples: tree(graph.root.appendingPathComponent("Example")),
            verifier: digest(graph.codeRoot.appendingPathComponent("ConsumerTests.swift")),
            toolchain: graph.native.toolchain,
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
            try ReleaseManager(graph: graph).verifyEmbeddedProvenance(extracted.deletingLastPathComponent(), index: index)
            paths[artifact.target] = extracted
        }
        return paths
    }

    func stagePackage(_ paths: [String: URL], index: ArtifactIndex, key: String, remote: Bool = false) throws -> URL {
        let stage = try graph.store.path("work/tests/\(key)/\(remote ? "remote-package" : "package")")
        try remove(stage)
        try mkdir(stage)
        for name in ["Sources", "Tests", "Example"] {
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
        _ = try graph.runner.doctor(graph.native.toolchain)
        let stage = try stagePackage([:], index: index, key: UUID().uuidString, remote: true)
        // Both workspace and SwiftPM download cache start empty; maintainer caches cannot hide a bad URL.
        try graph.runner.run(
            "/usr/bin/swift",
            ["package", "--package-path", stage.path, "--cache-path", stage.appendingPathComponent(".swiftpm-cache").path, "resolve"]
        )
        _ = try wrapperChecks(stage)
    }

    func run(_ candidate: URL, nativeOnly: Bool = false) throws -> URL {
        _ = try graph.runner.doctor(graph.native.toolchain)
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
            let fixtureDirectory = graph.root.appendingPathComponent("Tests/Resources")
            let fixtures = try read([String: String].self, fixtureDirectory.appendingPathComponent("Fixtures.lock.json"))
            for (name, sha) in fixtures {
                try require(
                    digest(fixtureDirectory.appendingPathComponent("Media/" + name)) == sha,
                    "Mandatory fixture checksum mismatch: \(name)"
                )
            }
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
            schemaVersion: 1,
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
        try graph.runner.run("/usr/bin/swift", ["test", "--package-path", stage.path, "--no-parallel"])
        checks.append("macos-swift-tests")
        try graph.runner.run("/usr/bin/swift", ["build", "--package-path", stage.path, "-c", "release"])
        checks.append("macos-release-package")
        let devices = try simulators()
        for (platform, prefix) in [("iOS Simulator", "iOS"), ("tvOS Simulator", "tvOS")] {
            guard let device = devices.first(where: { $0.runtime.contains("." + prefix + "-") })
            else { throw BuildError("Missing required \(prefix) simulator runtime") }
            try graph.runner.run(
                "/usr/bin/xcodebuild",
                [
                    "-scheme",
                    "MPVUI",
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
        let project = stage.appendingPathComponent("Example/MPVUIExample/MPVUIExample.xcodeproj")
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
                        scheme,
                        "-configuration",
                        configuration,
                        "-destination",
                        destination,
                        "-derivedDataPath",
                        stage.appendingPathComponent(".build/example-" + scheme).path,
                        "build",
                        "CODE_SIGNING_ALLOWED=NO"
                    ],
                    cwd: stage
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
            try graph.runner.run(
                "/usr/bin/xcodebuild",
                [
                    "-project",
                    project.path,
                    "-scheme",
                    scheme,
                    "-configuration",
                    "Release",
                    "-destination",
                    destination,
                    "-derivedDataPath",
                    stage.appendingPathComponent(".build/example-" + scheme).path,
                    "-archivePath",
                    stage.appendingPathComponent(".build/archives/" + scheme + ".xcarchive").path,
                    "archive",
                    "CODE_SIGNING_ALLOWED=NO"
                ],
                cwd: stage
            )
            checks.append("example/\(scheme)/archive")
        }
        return checks
    }

    struct Simulator { let id: String
        let runtime: String
        let state: String
    }

    func simulators() throws -> [Simulator] {
        let json = try graph.runner.run("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "--json"])
        guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let devices = object["devices"] as? [String: [[String: Any]]] else { throw BuildError("Invalid simulator inventory") }
        return devices.keys.sorted().reversed().flatMap { runtime in devices[runtime]!.compactMap { value in
            guard let id = value["udid"] as? String, let state = value["state"] as? String else { return nil }
            return Simulator(id: id, runtime: runtime, state: state)
        } }
    }

    func nativeConsumer(slice: Slice, arch: String, paths: [String: URL], work: URL) throws {
        let source = work.appendingPathComponent("smoke-\(slice.id)-\(arch).m")
        let imports = ProductDefinition.all.map { "@import \($0.framework);" }.joined(separator: "\n")
        try put(
            imports +
                // Simulate a host that already exports an incompatible FFmpeg.
                // mpv must use its own avcodec_version, while the host keeps 0.
                "\nunsigned avcodec_version(void) { return 0; }\n" +
                "int main(void) { mpv_handle *h = mpv_create(); if (!h) return 2; mpv_set_option_string(h, \"vo\", \"null\"); mpv_set_option_string(h, \"ao\", \"null\"); int rc = mpv_initialize(h); if (rc < 0) { mpv_destroy(h); return 3; } mpv_terminate_destroy(h); return avcodec_version() != 0; }\n",
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
