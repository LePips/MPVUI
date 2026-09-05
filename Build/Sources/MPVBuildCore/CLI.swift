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
            "release",
            "tag",
            "seed-inputs",
            "store",
            "ref"
        ]
        let flagOptions: Set<String> = [
            "offline",
            "fresh",
            "explain",
            "bootstrap",
            "check",
            "artifacts",
            "cache",
            "help",
            "artifacts-only",
            "inventory-only",
            "authenticated"
        ]
        var index = 0
        while index < raw.count {
            let argument = raw[index]
            if argument.hasPrefix("--") {
                var name = String(argument.dropFirst(2))
                // Keep existing scripts working while the public commands use clearer names.
                if name == "native" {
                    name = index + 1 < raw.count && !raw[index + 1].hasPrefix("--") ? "release" : "artifacts"
                }
                if name == "native-only" {
                    name = "artifacts-only"
                }
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

public enum CLI {
    static func defaultStore(_ root: URL) -> URL {
        let current = root.appendingPathComponent(".build/mpvbuild")
        let previous = root.appendingPathComponent(".build/native")
        // Reuse existing caches in place: installed build tools may contain absolute paths.
        return !exists(current) && exists(previous) ? previous : current
    }

    public static func run(_ raw: [String]) throws {
        // Native ar member modes and framework symlink modes must not inherit a caller's umask.
        umask(NativeEnvironment.fileCreationMask)
        let args = try Arguments(raw)
        if args.flags.contains("help") || args.positional.isEmpty {
            print("""
            mpvbuild doctor [--bootstrap]
            mpvbuild check [--artifacts --profile release]
            mpvbuild generate [--check] [--inventory-only]
            mpvbuild build --profile dev|release [--slices LIST --arch LIST] [--tag VERSION]
            mpvbuild test --candidate PATH [--artifacts-only]
            mpvbuild coverage [--profile release]
            mpvbuild repro [--profile release|dev --slices LIST --arch LIST]
            mpvbuild use local --artifact PATH | use remote
            mpvbuild release candidate [--tag VERSION] | publish --candidate PATH | adopt --release ID [--authenticated] | publish-package --tag VERSION
            mpvbuild update COMPONENT
            mpvbuild status | clean [--cache]
            Common: --jobs TOTAL --workers COUNT --offline --fresh --explain
            Migration: --seed-inputs PREVIOUS_CHECKOUT imports verified inputs only.
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
            root: URL(fileURLWithPath: args.values["store"] ?? Self.defaultStore(root).path),
            diagnostics: diagnostics
        )
        let operation = try FileLock(store.path("locks/operation.lock"), shared: args.positional[0] != "clean")
        defer { withExtendedLifetime(operation) {} }
        let toolPath = try Bootstrap.bin(store, native.toolchain).path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let runner = try Runner(
            developer: developer,
            epoch: native.sourceDateEpoch,
            logs: store.path("logs/\(UUID().uuidString)"),
            path: toolPath
        )
        defer {
            if args.positional[0] != "clean" {
                try? diagnostics.save(to: runner.logs.appendingPathComponent("metrics.json"))
            }
        }
        let inputs = InputStore(store: store, runner: runner, root: root, offline: args.flags.contains("offline"))
        let graph = BuildGraph(root: root, native: native, store: store, runner: runner, inputs: inputs)
        if let previous = args.values["seed-inputs"] {
            try inputs.seed(from: URL(fileURLWithPath: previous), lock: native)
        }
        switch args.positional[0] {
        case "doctor":
            if args.flags.contains("bootstrap") {
                try Bootstrap.run(native.toolchain, inputs: inputs)
            }
            let identities = try runner.doctor(native.toolchain)
            for key in identities.keys.sorted() {
                print("\(key): \(identities[key]!)")
            }
            print("doctor passed")
        case "coverage":
            _ = try runner.doctor(native.toolchain)
            try inputs.preflight(native, slices: slices)
            let builder = DependencyBuilder(inputs: inputs, runner: runner, store: store)
            var report: [DependencyEvidence] = []
            for slice in slices {
                for arch in slice.architectures {
                    for dependency in native.dependencies where dependency.slices.contains(slice.id) {
                        let product = try builder.materialize(dependency, slice: slice, arch: arch)
                        try report.append(read(DependencyEvidence.self, product.appendingPathComponent("coverage.json")))
                    }
                }
            }
            let output = try store.path("coverage.json")
            try write(report, output)
            print("Verified \(report.count) dependency targets: \(output.path)")
        case "repro":
            _ = try Reproducibility(graph: graph).run(profile: profile, slices: slices, jobs: args.positive("jobs", default: 8))
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
            print("Candidate: \(candidate.path)")
        case "generate":
            try Generator.generate(
                root: root,
                native: native,
                runner: runner,
                check: args.flags.contains("check"),
                inventoryOnly: args.flags.contains("inventory-only")
            )
        case "use":
            try require(args.positional.count == 2, "Expected use local --artifact PATH or use remote")
            let selection = PackageSelection(graph: graph)
            if args.positional[1] == "local" {
                guard let path = args.values["artifact"] else { throw BuildError("--artifact must name a candidate directory") }
                try selection.local(URL(fileURLWithPath: path))
            } else if args.positional[1] == "remote" {
                try selection.remote()
            } else {
                throw BuildError("Expected local or remote selection")
            }
        case "update":
            try require(args.positional.count == 2, "Expected update COMPONENT_OR_REF [--ref REF]")
            try print("Review update candidate: \(Updater(graph: graph).run(component: args.positional[1], ref: args.values["ref"]).path)")
        case "test":
            guard let candidate = args.values["candidate"] else { throw BuildError("test requires --candidate PATH") }
            try print(
                "Test receipt: \(ConsumerTests(graph: graph).run(URL(fileURLWithPath: candidate), nativeOnly: args.flags.contains("artifacts-only")).path)"
            )
        case "check":
            try runner.run("/usr/bin/swift", ["test", "--package-path", root.appendingPathComponent("Build").path])
            if args.flags.contains("artifacts") {
                try require(profile == "release", "Artifact check requires the release profile")
                let products = try graph.build(
                    slices: slices,
                    jobs: args.positive("jobs", default: 8),
                    workers: args.positive("workers", default: 2),
                    fresh: args.flags.contains("fresh")
                )
                let candidate = try Packager(graph: graph).package(
                    products,
                    slices: slices,
                    profile: "release",
                    fresh: args.flags.contains("fresh")
                )
                try print("Candidate tests: \(ConsumerTests(graph: graph).run(candidate).path)")
            } else {
                try Generator.generate(root: root, native: native, runner: runner, check: true)
                let index = try read(ArtifactIndex.self, root.appendingPathComponent("Build/Artifacts.lock.json"))
                try ConsumerTests(graph: graph).validateRemote(index)
            }
        case "release":
            try require(args.positional.count == 2, "Expected release candidate|publish|adopt|publish-package")
            let manager = ReleaseManager(graph: graph)
            switch args.positional[1] {
            case "candidate":
                try require(profile == "release", "Publication candidates require the complete release profile")
                let products = try graph.build(
                    slices: slices,
                    jobs: args.positive("jobs", default: 8),
                    workers: args.positive("workers", default: 2),
                    fresh: args.flags.contains("fresh")
                )
                let candidate = try Packager(graph: graph).package(
                    products,
                    slices: slices,
                    profile: "release",
                    fresh: args.flags.contains("fresh"),
                    tag: args.values["tag"]
                )
                let receipt = try ConsumerTests(graph: graph).run(candidate)
                try print("Publication bundle: \(manager.bundle(candidate: candidate, receipt: receipt).path)")
            case "publish", "publish-native":
                guard let path = args.values["candidate"] else { throw BuildError("--candidate PATH is required") }
                try manager.publishArtifacts(URL(fileURLWithPath: path))
            case "adopt":
                guard let id = args.values["release"] else { throw BuildError("--release RELEASE_ID is required") }
                try manager.adopt(id, authenticated: args.flags.contains("authenticated"))
            case "publish-package":
                guard let tag = args.values["tag"] else { throw BuildError("--tag VERSION is required") }
                try manager.publishPackage(tag)
            default: throw BuildError("Unknown release operation")
            }
        case "status":
            try print("build input lock: \(fingerprint(native))")
            print("selection: \(slices.map(\.id).joined(separator: ",")); \(slices.reduce(0) { $0 + $1.architectures.count }) thin builds")
            print("managed outputs: \(store.root.path)")
        case "clean": try store.clean(cache: args.flags.contains("cache"))
        default: throw BuildError("Unknown command: \(args.positional.joined(separator: " "))")
        }
    }
}
