import Darwin
import Foundation

struct Arguments {

    var positional: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String]) throws {
        let valueOptions: Set<String> = [
            "root",
            "profile",
            "slices",
            "arch",
            "jobs",
            "workers",
            "artifact",
            "candidate",
            "bundle",
            "release",
            "tag",
            "store"
        ]

        let flagOptions: Set<String> = [
            "offline",
            "fresh",
            "explain",
            "bootstrap",
            "remote",
            "cache",
            "help",
            "authenticated"
        ]

        var index = 0

        while index < raw.count {
            let argument = raw[index]

            if argument.hasPrefix("--") {
                let name = String(argument.dropFirst(2))

                if valueOptions.contains(name) {
                    try require(
                        values[name] == nil && index + 1 < raw.count && !raw[index + 1].hasPrefix("--"),
                        "Missing or duplicate --\(name)"
                    )

                    index += 1
                    values[name] = raw[index]
                } else {
                    try require(flagOptions.contains(name) && !flags.contains(name), "Unknown/duplicate option \(argument)")
                    flags.insert(name)
                }
            } else {
                positional.append(argument)
            }

            index += 1
        }
    }

    func positive(_ name: String, default fallback: Int) throws -> Int {
        guard let raw = values[name] else { return fallback }
        guard let value = Int(raw), value > 0 else { throw BuildError("--\(name) must be a positive integer") }

        return value
    }
}

/// The command-line entry point for native library builds.
public enum CLI {

    /// Runs the supplied command-line arguments, throwing if validation or execution fails.
    public static func run(_ raw: [String]) throws {
        // Native ar member modes and framework symlink modes must not inherit a caller's umask.
        umask(NativeEnvironment.fileCreationMask)

        let args = try Arguments(raw)

        if args.flags.contains("help") || args.positional.isEmpty {
            print("""
            mpvbuild doctor [--bootstrap]
            mpvbuild build [--profile dev|release] [--slices LIST --arch LIST] [--tag VERSION] [--fresh] [--offline]
            mpvbuild select [--artifact PATH | --remote]
            mpvbuild release candidate [--tag VERSION] [--candidate PATH] [--fresh] [--offline]
            mpvbuild release publish --bundle PATH | adopt --release ID [--authenticated] | package --tag VERSION
            mpvbuild release check | repro [--profile dev|release] | audit
            mpvbuild clean [--cache]

            build checks each candidate's native artifacts. select uses the latest candidate unless given another.
            MPVUI_IOS_SIMULATOR and MPVUI_TVOS_SIMULATOR choose release test simulator identifiers.
            """)
            return
        }

        let root = URL(fileURLWithPath: args.values["root"] ?? fm.currentDirectoryPath).standardizedFileURL

        // Finish or roll back any interrupted multi-file generation before reading its inputs.
        do { let recovery = try FileTransaction(root: root)
            withExtendedLifetime(recovery) {}
        }

        let native = try read(NativeLock.self, root.appendingPathComponent("Build/Inputs.lock.json"))
        try native.validate(root: root)

        let profile = args.values["profile"] ?? (args.positional[0] == "build" ? "dev" : "release")

        if let tag = args.values["tag"], args.positional[0] == "build" || args.positional == ["release", "candidate"] {
            try require(profile == "release", "Versioned artifacts require the release profile")
            try require(Generator.isVersionTag(tag), "Release tag must be SemVer")
        }
        #if arch(arm64)
        let host = "arm64"
        #else
        let host = "x86_64"
        #endif
        // Selection validation deliberately precedes store creation, fetches and cleaning.
        let slices = try native.selected(profile: profile, sliceNames: args.values["slices"], archNames: args.values["arch"], host: host)

        guard let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
        else { throw BuildError("Run via Build/mpvbuild or set DEVELOPER_DIR") }

        let diagnostics = BuildDiagnostics(explain: args.flags.contains("explain"))

        let store = try ManagedStore(
            root: URL(fileURLWithPath: args.values["store"] ?? root.appendingPathComponent(".build/mpvbuild").path),
            diagnostics: diagnostics
        )

        let operation = try FileLock(store.path("locks/operation.lock"), shared: args.positional[0] != "clean")
        defer { withExtendedLifetime(operation) {} }

        let toolPath = try Bootstrap.bin(store, native.apple.toolchain).path + """
        :/opt/homebrew/bin:/usr/local/bin:/usr/b\
        in:/bin:/usr/sbin:/sbin
        """
        let runner = try Runner(
            developer: developer,
            epoch: native.apple.sourceDateEpoch,
            logs: store.path("logs/\(UUID().uuidString)"),
            path: toolPath
        )

        var validationArtifacts = ["nativeLogs": runner.logs.path]
        var validationSummary = ["profile": profile, "operation": args.positional.joined(separator: " ")]

        defer {
            if args.positional[0] != "clean" {
                try? diagnostics.save(to: runner.logs.appendingPathComponent("metrics.json"))
            }

            if let destination = ProcessInfo.processInfo.environment["MPVUI_VALIDATION_EVIDENCE"] {
                struct Evidence: Encodable {

                    let summary: [String: String]
                    let artifacts: [String: String]
                }

                try? write(
                    Evidence(
                        summary: validationSummary,
                        artifacts: validationArtifacts
                    ),
                    URL(fileURLWithPath: destination)
                )
            }
        }

        let inputs = InputStore(store: store, runner: runner, root: root, offline: args.flags.contains("offline"))
        let graph = BuildGraph(root: root, native: native, store: store, runner: runner, inputs: inputs)

        switch args.positional[0] {
        case "doctor":
            if args.flags.contains("bootstrap") {
                try Bootstrap.run(native.apple.toolchain, inputs: inputs)
            }

            let identities = try runner.doctor(native.apple.toolchain)

            for key in identities.keys.sorted() {
                print("\(key): \(identities[key]!)")
            }

            validationSummary["inputFingerprint"] = try fingerprint(native)
            validationArtifacts["managedOutputs"] = store.root.path
            print("build input lock: \(validationSummary["inputFingerprint"]!)")
            print("managed outputs: \(store.root.path)")
            print("doctor passed")

        case "build":
            let jobs = try args.positive("jobs", default: min(8, ProcessInfo.processInfo.activeProcessorCount))
            let workers = try args.positive("workers", default: 2)
            let products = try graph.build(slices: slices, jobs: jobs, workers: workers, fresh: args.flags.contains("fresh"))
            let output = try store.path("thin-products.json")
            try write(products, output)

            let candidate = try Packager(graph: graph).package(
                products,
                slices: slices,
                profile: profile,
                fresh: args.flags.contains("fresh"),
                tag: args.values["tag"]
            )
            validationArtifacts["nativeCandidate"] = candidate.path
            print("Candidate: \(candidate.path)")

            // Every slice gets import, link and symbol isolation checks. Release adds the full consumer suite.
            let receipt = try ConsumerTests(graph: graph).run(candidate, nativeOnly: true)
            validationArtifacts["nativeTestReceipt"] = receipt.path
            try store.recordLatestCandidate(candidate)
            print("Native checks: \(receipt.path)")

        case "select":
            let selection = PackageSelection(graph: graph)

            if args.flags.contains("remote") {
                try require(args.values["artifact"] == nil, "Choose --artifact or --remote")
                try selection.remote()
            } else {
                try selection.local(args.values["artifact"].map { URL(fileURLWithPath: $0) } ?? store.latestCandidate())
            }

        case "release":
            try require(args.positional.count == 2, "Expected release candidate|publish|adopt|package|check|repro|audit")

            let manager = ReleaseManager(graph: graph)

            switch args.positional[1] {
            case "candidate":
                try require(profile == "release", "Publication candidates require the complete release profile")

                let candidate: URL

                if let path = args.values["candidate"] {
                    try require(!args.flags.contains("fresh"), "--fresh cannot reuse an existing candidate")
                    candidate = URL(fileURLWithPath: path).standardizedFileURL
                    try manager.validateCandidate(candidate, tag: args.values["tag"])
                } else {
                    let products = try graph.build(
                        slices: slices,
                        jobs: args.positive("jobs", default: 8),
                        workers: args.positive("workers", default: 2),
                        fresh: args.flags.contains("fresh")
                    )

                    candidate = try Packager(graph: graph).package(
                        products,
                        slices: slices,
                        profile: "release",
                        fresh: args.flags.contains("fresh"),
                        tag: args.values["tag"]
                    )

                    try store.recordLatestCandidate(candidate)
                }

                validationArtifacts["nativeCandidate"] = candidate.path

                let receipt = try ConsumerTests(graph: graph).run(candidate)
                validationArtifacts["nativeTestReceipt"] = receipt.path

                let bundle = try manager.bundle(candidate: candidate, receipt: receipt)
                validationArtifacts["publicationBundle"] = bundle.path
                print("Publication bundle: \(bundle.path)")

            case "publish":
                guard let path = args.values["bundle"] else { throw BuildError("--bundle PATH is required") }

                try manager.publishArtifacts(URL(fileURLWithPath: path))

            case "adopt":
                guard let id = args.values["release"] else { throw BuildError("--release RELEASE_ID is required") }

                try manager.adopt(id, authenticated: args.flags.contains("authenticated"))

            case "package":
                guard let tag = args.values["tag"] else { throw BuildError("--tag VERSION is required") }

                try manager.publishPackage(tag)

            case "check":
                try Generator.check(root: root, native: native, runner: runner)

                let index = try read(ArtifactIndex.self, root.appendingPathComponent("Build/Artifacts.lock.json"))
                try ConsumerTests(graph: graph).validateRemote(index)

            case "repro":
                _ = try Reproducibility(graph: graph).run(profile: profile, slices: slices, jobs: args.positive("jobs", default: 8))

            case "audit":
                _ = try runner.doctor(native.apple.toolchain)
                try inputs.preflight(native, slices: slices)

                let builder = DependencyBuilder(inputs: inputs, runner: runner, store: store)
                var report: [DependencyEvidence] = []

                for slice in slices {
                    for arch in slice.architectures {
                        for dependency in native.apple.dependencies where dependency.slices.contains(slice.id) {
                            let product = try builder.materialize(dependency, slice: slice, arch: arch)
                            try report.append(read(DependencyEvidence.self, product.appendingPathComponent("coverage.json")))
                        }
                    }
                }

                let output = try store.path("audit.json")
                try write(report, output)
                print("Verified \(report.count) dependency targets: \(output.path)")

            default: throw BuildError("Unknown release operation")
            }

        case "clean": try store.clean(cache: args.flags.contains("cache"))

        default: throw BuildError("Unknown command: \(args.positional.joined(separator: " "))")
        }
    }
}
