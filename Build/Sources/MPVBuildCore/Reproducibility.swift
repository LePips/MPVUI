import Foundation

struct Reproducibility {
    let graph: BuildGraph
    struct Resources: Codable {
        let userCPUSeconds: Double
        let systemCPUSeconds: Double
        let maximumResidentBytes: UInt64
        static func parse(_ output: String) throws -> Self {
            let lines = output.components(separatedBy: "\n").map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
            guard let user = lines.last(where: { $0.first == "user" && $0.count == 2 }).flatMap({ Double($0[1]) }),
                  let system = lines.last(where: { $0.first == "sys" && $0.count == 2 }).flatMap({ Double($0[1]) }),
                  let resident = lines.last(where: { $0.dropFirst().joined(separator: " ") == "maximum resident set size" })
                      .flatMap({ UInt64($0[0]) })
            else {
                throw BuildError("Missing native audit CPU/memory measurements")
            }
            return Self(userCPUSeconds: user, systemCPUSeconds: system, maximumResidentBytes: resident)
        }
    }

    struct Result: Codable {
        let label: String
        let seconds: Double
        let candidate: String
        let checksums: [String: String]
        let nativeBuilds: [String]
        let nativeReuses: [String]
        let resources: Resources
        // Each measured build is offline; immutable input acquisition is outside the compile benchmark.
        let downloadedBytes: Int
    }

    func run(profile: String, slices: [Slice], jobs: Int) throws -> URL {
        try graph.inputs.preflight(graph.native, slices: slices)
        // Populate immutable inputs once; fresh audits retain downloads but never reuse compiled products.
        for source in graph.native.sources {
            _ = try graph.inputs.prepare(source)
        }
        for dependency in graph.native.dependencies where !Set(dependency.slices).isDisjoint(with: slices.map(\.id)) {
            _ = try graph.inputs.extracted(url: dependency.url, sha: dependency.sha256)
            for asset in dependency.runtime {
                _ = try graph.inputs.extracted(url: asset.url, sha: asset.sha256)
            }
        }
        let audit = try graph.store.path("audits/repro-\(UUID().uuidString)")
        try mkdir(audit)
        var results: [Result] = []
        for location in ["first checkout", "different/deeper checkout"] {
            let root = audit.appendingPathComponent(location)
            try stageCheckout(at: root)
            let store = try ManagedStore(root: root.appendingPathComponent(".build/mpvbuild"))
            for name in ["downloads", "extracted"] {
                try Self.copyImmutableCache(graph.store.path(name), to: store.path(name))
            }
            try fm.copyItem(at: graph.store.path("git"), to: store.path("git"))
            // Checksum-locked tool installations are inputs as well. Absolute symlinks only identify validated tools.
            let toolchains = try graph.store.path("toolchains")
            if exists(toolchains) {
                try fm.copyItem(at: toolchains, to: store.path("toolchains"))
            }
            let first = location == "first checkout"
            let cold = try build(
                root: root,
                label: first ? "cold" : "different-path-timezone-umask-workers",
                profile: profile,
                slices: slices,
                jobs: jobs,
                workers: first ? 1 : min(2, jobs),
                timezone: first ? "Pacific/Honolulu" : "Asia/Tokyo",
                mask: first ? "077" : "022"
            )
            results.append(cold)
            if first {
                let warm = try build(
                    root: root,
                    label: "warm",
                    profile: profile,
                    slices: slices,
                    jobs: jobs,
                    workers: 1,
                    timezone: "UTC",
                    mask: "022"
                )
                try require(
                    warm.nativeBuilds.isEmpty && warm.checksums == cold.checksums,
                    "Warm build compiled native code or changed ZIP bytes"
                )
                results.append(warm)
                let recipe = root.appendingPathComponent("Build/Sources/MPVBuildCore/Recipes/MPVRecipe.swift")
                try put(
                    String(contentsOf: recipe, encoding: .utf8) + "\n// Reproducibility audit: mpv-only implementation change.\n",
                    recipe
                )
                let mpvOnly = try build(
                    root: root,
                    label: "mpv-only",
                    profile: profile,
                    slices: slices,
                    jobs: jobs,
                    workers: 1,
                    timezone: "UTC",
                    mask: "022"
                )
                try require(
                    !mpvOnly.nativeBuilds.isEmpty && mpvOnly.nativeBuilds.allSatisfy { $0.hasPrefix("mpv/") } && mpvOnly.nativeReuses
                        .contains { $0.hasPrefix("ffmpeg/") },
                    "mpv-only edit failed component isolation"
                )
                try require(mpvOnly.checksums == cold.checksums, "An mpv-only comment changed native ZIP bytes")
                results.append(mpvOnly)
            } else {
                try require(
                    cold.checksums == results[0].checksums,
                    "Different checkout path/timezone/umask/worker count changed native ZIP bytes"
                )
            }
            try write(results, audit.appendingPathComponent("results.json"))
            // Keep the verified products, ZIPs, source snapshot and logs; reclaim disposable compiler scratch
            // before starting the second independent build to limit local disk usage.
            try remove(store.path("work"))
            try remove(root.appendingPathComponent(".build/mpvbuild-cli"))
        }
        print("Reproducibility and incremental-build audit passed: \(audit.path)")
        return audit
    }

    func stageCheckout(at root: URL) throws {
        // Copy only build inputs: Build is also a Swift package and may contain its own .build cache.
        for name in [
            "Build/mpvbuild",
            "Build/Package.swift",
            "Build/Sources",
            "Build/Tests",
            "Build/Patches",
            "Build/Support",
            "Build/RECIPE_LICENSE",
            "Sources",
            "Tests",
            "Example",
            "Package.swift"
        ] {
            let source = graph.root.appendingPathComponent(name)
            let destination = root.appendingPathComponent(name)
            try mkdir(destination.deletingLastPathComponent())
            try fm.copyItem(at: source, to: destination)
        }
        let copiedCore = root.appendingPathComponent("Build/Sources/MPVBuildCore")
        try remove(copiedCore)
        try fm.copyItem(at: graph.codeRoot, to: copiedCore)
        try write(graph.native, root.appendingPathComponent("Build/Inputs.lock.json"))
    }

    static func copyImmutableCache(_ source: URL, to destination: URL) throws {
        try require(!exists(destination), "Immutable cache destination must be new")
        try mkdir(destination)
        for file in try files(source) {
            let relative = String(file.path.dropFirst(source.path.count + 1))
            let output = destination.appendingPathComponent(relative)
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
            if values.isSymbolicLink == true {
                try fm.createSymbolicLink(
                    atPath: output.path,
                    withDestinationPath: fm.destinationOfSymbolicLink(atPath: file.path)
                )
            } else if values.isDirectory == true {
                try mkdir(output)
            } else if values.isRegularFile == true {
                try fm.linkItem(at: file, to: output)
            } else {
                throw BuildError("Unexpected immutable cache file type")
            }
        }
    }

    func build(
        root: URL,
        label: String,
        profile: String,
        slices: [Slice],
        jobs: Int,
        workers: Int,
        timezone: String,
        mask: String
    ) throws -> Result {
        let started = Date()
        var args = [
            root.appendingPathComponent("Build/mpvbuild").path,
            "build",
            "--profile",
            profile,
            "--offline",
            "--jobs",
            String(jobs),
            "--workers",
            String(workers)
        ]
        if profile == "dev" {
            args += [
                "--slices",
                slices.map(\.id).joined(separator: ","),
                "--arch",
                Set(slices.flatMap(\.architectures)).sorted().joined(separator: ",")
            ]
        }
        let output = try graph.runner.run(
            "/usr/bin/time",
            ["-lp", "/bin/sh", "-c", "umask \(mask); exec \"$@\"", "mpvbuild-audit"] + args,
            cwd: root,
            env: ["TZ": timezone],
            combined: true
        )
        guard let line = output.components(separatedBy: "\n").last(where: { $0.hasPrefix("Candidate: ") })
        else { throw BuildError("Audit candidate path missing") }
        let candidate = URL(fileURLWithPath: String(line.dropFirst("Candidate: ".count)))
        let index = try read(ArtifactIndex.self, candidate.appendingPathComponent("Artifacts.lock.json"))
        let nativeBuilds = output.components(separatedBy: "\n")
            .filter { $0.hasPrefix("build products/mpv/") || $0.hasPrefix("build products/ffmpeg/") }
            .map { String($0.dropFirst("build products/".count)).components(separatedBy: " ")[0] }
        let nativeReuses = output.components(separatedBy: "\n")
            .filter { $0.hasPrefix("reuse products/mpv/") || $0.hasPrefix("reuse products/ffmpeg/") }
            .map { String($0.dropFirst("reuse products/".count)).components(separatedBy: " ")[0] }
        return try Result(
            label: label,
            seconds: Date().timeIntervalSince(started),
            candidate: candidate.path,
            checksums: Dictionary(uniqueKeysWithValues: index.products.map { ($0.archive, $0.sha256) }),
            nativeBuilds: nativeBuilds,
            nativeReuses: nativeReuses,
            resources: Resources.parse(output),
            downloadedBytes: 0
        )
    }
}
