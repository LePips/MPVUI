import Foundation

struct ComponentKey: Encodable {
    let component: String
    let sourceTree: String
    let implementation: [String: String]
    let tools: [String: String]
    let slice: Slice
    let features: Features
    let sourceDateEpoch: Int
    let dependencies: [String: String]
    let environment: [String: String]
}

struct ThinProduct: Codable, Sendable {
    let component: String
    let slice: Slice
    let architecture: String
    let nodeKey: String
    let contentDigest: String
    let directory: String
}

struct BuildGraph: Sendable {
    let root: URL
    let native: NativeLock
    let store: ManagedStore
    let runner: Runner
    let inputs: InputStore
    var codeRoot: URL {
        if let snapshot = ProcessInfo.processInfo.environment["MPVBUILD_CODE_ROOT"] {
            return URL(fileURLWithPath: snapshot)
        }
        return root.appendingPathComponent("Build/Sources/MPVBuildCore")
    }

    func implementation(component: String) throws -> [String: String] {
        let core = codeRoot
        var result: [String: String] = [:]
        let recipeFiles: Set<String> = ["Model.swift", "Recipes/NativeRecipe.swift", "Recipes/FFmpegFlags.swift"]
        for file in try files(core) where file.pathExtension == "swift" {
            let relative = String(file.path.dropFirst(core.path.count + 1))
            guard recipeFiles.contains(relative) || (component == "mpv" && relative == "Recipes/MPVRecipe.swift") else { continue }
            result[relative] = try digest(file)
        }
        for (name, value) in try tree(root.appendingPathComponent("Build/Support")) {
            result["support/" + name] = value
        }
        return result
    }

    static let operationalFiles: Set<String> = [
        "CLI.swift",
        "Generation.swift",
        "Publication.swift",
        "ConsumerTests.swift",
        "Selection.swift",
        "Update.swift",
        "Bootstrap.swift",
        "Diagnostics.swift",
        "Reproducibility.swift"
    ]
    func component(
        _ id: String,
        source: URL,
        slice: Slice,
        arch: String,
        dependencies: [String: URL],
        tools: [String: String],
        jobs: Int,
        fresh: Bool
    ) throws -> ThinProduct {
        var dependencyDigests: [String: String] = [:]
        for (name, path) in dependencies {
            dependencyDigests[name] = try fingerprint(tree(path, excluding: ["record.json"]))
        }
        let environmentKeys: Set<String> = [
            "LC_ALL",
            "LANG",
            "TZ",
            "SOURCE_DATE_EPOCH",
            "ZERO_AR_DATE",
            "COPYFILE_DISABLE",
            "PYTHONHASHSEED"
        ]
        let environment = runner.environment.filter { environmentKeys.contains($0.key) }.merging(["umask": String(
            NativeEnvironment.fileCreationMask,
            radix: 8
        )]) { _, new in new }
        let key = try fingerprint(ComponentKey(
            component: id,
            sourceTree: fingerprint(tree(source)),
            implementation: implementation(component: id),
            tools: tools,
            slice: slice.selecting([arch]),
            features: native.features,
            sourceDateEpoch: native.sourceDateEpoch,
            dependencies: dependencyDigests,
            environment: environment
        ))
        var built = false
        func validate(_ prefix: URL) throws {
            for library in id == "mpv" ? ["mpv"] : FFmpegRecipe.libraries {
                let binary = prefix.appendingPathComponent("lib/lib\(library).a")
                _ = try MachO.validate(binary, slice: slice, arch: arch)
                if id == "mpv" {
                    try verifyMPV(binary, slice: slice, contracts: native.contracts, runner: runner)
                }
            }
        }
        let output = try store.node(
            stage: "products",
            name: "\(id)/\(slice.id)-\(arch)",
            key: key,
            dependencies: dependencyDigests,
            fresh: fresh
        ) { prefix in
            // A killed CLI can leave an orphan compiler alive after its node lock is released.
            // Each attempt therefore owns a new scratch path as well as a unique product staging path.
            let work = try store.path("work/\(id)/\(slice.id)-\(arch)/\(key)-\(UUID().uuidString)")
            try mkdir(work)
            let copy = work.appendingPathComponent("source")
            try fm.copyItem(at: source, to: copy)
            let context = try RecipeContext(
                component: id,
                slice: slice,
                arch: arch,
                source: copy,
                work: work,
                prefix: prefix,
                sdk: runner.sdk(slice.sdk),
                dependencies: dependencies,
                root: root,
                runner: runner,
                jobs: jobs,
                version: native.source(id).version
            )
            if id == "ffmpeg" {
                try FFmpegRecipe.build(context)
            } else {
                try MPVRecipe.build(context)
            }
            try validate(prefix)
            built = true
            // Resolved configuration and command output are retained in the product and logs.
            // Successful compiler scratch is disposable; failed attempts remain for diagnosis.
            try remove(work)
            return ["all-object-platforms", "minimum-OS", "expected-libraries", "compiled-contracts"]
        }
        // Validation code and contracts can evolve without forcing unrelated recompilation.
        // Always apply the current verifier to reused native products.
        if !built {
            try validate(output)
        }
        return try ThinProduct(
            component: id,
            slice: slice,
            architecture: arch,
            nodeKey: key,
            contentDigest: fingerprint(tree(output, excluding: ["record.json"])),
            directory: String(output.path.dropFirst(store.root.path.count + 1))
        )
    }

    func build(slices: [Slice], jobs: Int, workers: Int, fresh: Bool) throws -> [ThinProduct] {
        let tools = try runner.doctor(native.toolchain)
        try inputs.preflight(native, slices: slices)
        let dependencyBuilder = DependencyBuilder(inputs: inputs, runner: runner, store: store)
        var targets: [TargetInputs] = []
        // Complete coverage preflight before the first native configure invocation.
        for slice in slices {
            for arch in slice.architectures {
                var dependencies: [String: URL] = [:]
                for dependency in native.dependencies
                    where dependency.slices.contains(slice.id)
                {
                    dependencies[dependency.id] = try dependencyBuilder.materialize(
                        dependency,
                        slice: slice,
                        arch: arch
                    )
                }
                targets.append(TargetInputs(slice: slice, arch: arch, dependencies: dependencies))
            }
        }
        let sources = try Dictionary(uniqueKeysWithValues: native.sources.map { try ($0.id, inputs.prepare($0)) })
        let width = max(1, min(workers, jobs, targets.count))
        let perWorker = max(1, jobs / width)
        let results = WorkerResults()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = width
        for target in targets {
            queue.addOperation {
                if results.failed {
                    return
                }
                do {
                    var dependencies = target.dependencies
                    let ffDependencies = dependencies
                        .filter { entry in native.dependencies.first(where: { $0.id == entry.key })!.consumers.contains("ffmpeg") }
                    let ff = try component(
                        "ffmpeg",
                        source: sources["ffmpeg"]!,
                        slice: target.slice,
                        arch: target.arch,
                        dependencies: ffDependencies,
                        tools: tools,
                        jobs: perWorker,
                        fresh: fresh
                    )
                    dependencies["ffmpeg"] = try store.path(ff.directory)
                    let mpv = try component(
                        "mpv",
                        source: sources["mpv"]!,
                        slice: target.slice,
                        arch: target.arch,
                        dependencies: dependencies,
                        tools: tools,
                        jobs: perWorker,
                        fresh: fresh
                    )
                    results.append([ff, mpv])
                } catch { results.fail(error) }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        return try results.get().sorted { ($0.slice.id, $0.architecture, $0.component) < ($1.slice.id, $1.architecture, $1.component) }
    }
}

private struct TargetInputs: Sendable { let slice: Slice
    let arch: String
    let dependencies: [String: URL]
}

private final class WorkerResults: @unchecked Sendable {
    private let lock = NSLock()
    private var products: [ThinProduct] = []
    private var error: Error?
    var failed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return error != nil
    }

    func append(_ values: [ThinProduct]) {
        lock.lock()
        defer { lock.unlock() }
        products += values
    }

    func fail(_ failure: Error) {
        lock.lock()
        defer { lock.unlock() }
        if error == nil {
            error = failure
        }
    }

    func get() throws -> [ThinProduct] {
        lock.lock()
        defer { lock.unlock() }
        if let error {
            throw error
        }
        return products
    }
}

func verifyMPV(_ binary: URL, slice: Slice, contracts: Contracts, runner: Runner) throws {
    try require(
        (fm.attributesOfItem(atPath: binary.path)[.size] as? NSNumber)?.intValue ?? 0 >= contracts.minimumMPVBytes,
        "Implausibly small libmpv archive"
    )
    let members = try Set(runner.run("/usr/bin/ar", ["-t", binary.path]).components(separatedBy: "\n"))
    for member in contracts.mpvMembers {
        try require(members.contains(member), "Missing compiled patch member \(member)")
    }
    if slice.id == "macos" {
        try require(members.contains(contracts.macOSSwiftMember), "Missing macOS Swift object")
    }
    let definitions = try Set(runner.run("/usr/bin/nm", ["-Uj", binary.path]).components(separatedBy: "\n"))
    for symbol in contracts.mpvDefinitions {
        try require(definitions.contains(symbol), "Missing symbol definition \(symbol)")
    }
    let references = try Set(runner.run("/usr/bin/nm", ["-uj", binary.path]).components(separatedBy: "\n"))
    for symbol in contracts.mpvReferences {
        try require(references.contains(symbol), "Missing required external reference \(symbol)")
    }
    let bytes = try Data(contentsOf: binary)
    for string in contracts.mpvStrings {
        try require(
            bytes.range(of: Data(string.utf8)) != nil,
            "Missing compiled contract string: \(string)"
        )
    }
}
