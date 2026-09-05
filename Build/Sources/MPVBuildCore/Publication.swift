import Foundation

/// The upload state machine is independent of candidate validation, so interruptions can be tested without a release service.
struct ArtifactPublication {
    let release: () throws -> [String: Any]?
    let create: () throws -> Void
    let upload: (URL) throws -> Void
    let download: ([String: Any], URL) throws -> Void
    let publish: () throws -> Void
    func run(bundle: URL, expected: [String], marker: String, verification: URL) throws {
        if try release() == nil {
            try create()
        }
        guard var current = try release() else { throw BuildError("Draft release was not created") }
        func inventory(_ value: [String: Any]) throws -> [String: [String: Any]] {
            try require(
                (value["body"] as? String)?.components(separatedBy: "\n").contains(marker) == true,
                "Existing release is not an owned matching candidate"
            )
            guard let assets = value["assets"] as? [[String: Any]] else { throw BuildError("Missing asset inventory") }
            var result: [String: [String: Any]] = [:]
            for asset in assets {
                guard let name = asset["name"] as? String else { throw BuildError("Missing asset name") }
                try require(result[name] == nil && expected.contains(name), "Duplicate or unexpected published asset")
                result[name] = asset
            }
            return result
        }
        var existing = try inventory(current)
        for name in expected {
            let file = try contained(bundle, name)
            if existing[name] == nil {
                try require(current["draft"] as? Bool == true, "Published release is incomplete; refusing to mutate it")
                try upload(file)
                guard let refreshed = try release() else { throw BuildError("Draft disappeared") }
                current = refreshed
                existing = try inventory(current)
            }
            guard let asset = existing[name] else { throw BuildError("Uploaded asset missing: \(name)") }
            let downloaded = verification.appendingPathComponent("verify-" + name)
            try download(asset, downloaded)
            try require(digest(downloaded) == digest(file), "Existing/uploaded asset differs; refusing overwrite: \(name)")
        }
        if current["draft"] as? Bool == true {
            try publish()
        }
    }
}

struct Provenance: Codable {
    let schemaVersion: Int
    let nativeInputFingerprint: String
    let sourceCommit: String
    let sourceRepository: String?
    let sourceWasDirty: Bool
    let hostArchitecture: String
    let toolchain: [String: String]
    let artifacts: [String: String]
    let tests: ConsumerTestRecord
    let createdAt: String
}

struct ReleaseManager {
    let graph: BuildGraph
    var repository: String {
        graph.native.publication.repository
    }

    static func publishedFiles(_ index: ArtifactIndex) -> [String] {
        index.products.map(\.archive) + ["Artifacts.lock.json", "Inputs.lock.json"]
    }

    static func githubRepository(_ remote: String) throws -> String {
        let prefixes = ["https://github.com/", "ssh://git@github.com/", "git@github.com:"]
        guard let prefix = prefixes.first(where: remote.hasPrefix)
        else { throw BuildError("Publication requires a GitHub origin repository") }
        var name = String(remote.dropFirst(prefix.count))
        if name.hasSuffix(".git") {
            name.removeLast(4)
        }
        try require(
            name.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
            "Invalid GitHub origin repository"
        )
        return name
    }

    func sourceRepository() throws -> String {
        try Self.githubRepository(graph.runner.run("git", ["remote", "get-url", "origin"], cwd: graph.root))
    }

    var credentials: [String: String] {
        var result: [String: String] = [:]
        for name in ["GH_TOKEN", "GITHUB_TOKEN", "GH_HOST", "GH_CONFIG_DIR"] {
            if let value = ProcessInfo.processInfo.environment[name] {
                result[name] = value
            }
        }
        return result
    }

    @discardableResult
    func gh(_ args: [String], output: URL? = nil) throws -> String {
        try require(!graph.inputs.offline, "Release network operations are unavailable with --offline")
        return try graph.runner.run("gh", args, env: credentials, output: output)
    }

    func verifyPublicURL(_ artifact: Artifact) throws {
        try require(!graph.inputs.offline, "Public URL verification requires network access")
        let file = graph.runner.logs.appendingPathComponent("public-\(UUID().uuidString).zip")
        defer { try? remove(file) }
        try graph.runner.run(
            "/usr/bin/curl",
            ["--fail", "--location", "--retry", "3", "--proto", "=https", "--proto-redir", "=https", "--output", file.path, artifact.url]
        )
        try require(digest(file) == artifact.sha256, "Public consumer URL returned different bytes: \(artifact.target)")
    }

    func sourceNotices() throws -> Data {
        var notices = "MPVUI source notices\n\nBuild inputs, dependency artifacts and ordered patches are identified in Inputs.lock.json.\n"
        for source in graph.native.sources {
            let prepared = try graph.inputs.prepare(source)
            notices += "\n\(source.id) — \(source.commit)\n"
            let names = source.id == "mpv" ? ["Copyright", "LICENSE.GPL", "LICENSE.LGPL"] : [
                "LICENSE.md",
                "COPYING.GPLv3",
                "COPYING.LGPLv3"
            ]
            for name in names {
                try notices += "\n===== \(source.id)/\(name) =====\n" + String(
                    contentsOf: prepared.appendingPathComponent(name),
                    encoding: .utf8
                ) + "\n"
            }
        }
        return Data(notices.utf8)
    }

    func bundle(candidate: URL, receipt: URL) throws -> URL {
        let index = try read(ArtifactIndex.self, candidate.appendingPathComponent("Artifacts.lock.json"))
        try Generator.validate(index, native: graph.native, release: true)
        let tests = try read(ConsumerTestRecord.self, receipt)
        try require(
            tests.complete && tests.key == ConsumerTests(graph: graph).testKey(index, nativeOnly: false),
            "Stale candidate test receipt"
        )
        let artifacts = Dictionary(uniqueKeysWithValues: index.products.map { ($0.archive, $0.sha256) })
        try require(tests.artifactDigests == artifacts, "Tests refer to different artifact bytes")
        let sourceCommit = try graph.runner.run("git", ["rev-parse", "HEAD"], cwd: graph.root)
        let dirty = try !graph.runner.run("git", ["status", "--porcelain"], cwd: graph.root).isEmpty
        let provenance = try Provenance(
            schemaVersion: 1,
            nativeInputFingerprint: index.nativeInputFingerprint,
            sourceCommit: sourceCommit,
            sourceRepository: sourceRepository(),
            sourceWasDirty: dirty,
            hostArchitecture: graph.runner.run("/usr/bin/uname", ["-m"]),
            toolchain: graph.runner.doctor(graph.native.toolchain),
            artifacts: artifacts,
            tests: tests,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        let notices = try sourceNotices()
        let key = try fingerprint([
            "native": index.nativeInputFingerprint,
            "tests": tests.key,
            "artifacts": fingerprint(artifacts),
            "commit": sourceCommit,
            "dirty": String(dirty),
            "notices": hash(notices),
            "publication": digest(graph.codeRoot.appendingPathComponent("Publication.swift"))
        ])
        return try graph.store.node(stage: "bundles", name: index.releaseID, key: key) { output in
            for artifact in index.products {
                let file = candidate.appendingPathComponent(artifact.archive)
                try require(digest(file) == artifact.sha256, "Candidate changed before bundling")
                try fm.copyItem(at: file, to: output.appendingPathComponent(artifact.archive))
            }
            for name in ["Artifacts.lock.json", "Inputs.lock.json", "RECIPE_LICENSE"] {
                try fm.copyItem(
                    at: candidate.appendingPathComponent(name),
                    to: output.appendingPathComponent(name)
                )
            }
            try put(notices, output.appendingPathComponent("SOURCE_NOTICES.txt"))
            try write(provenance, output.appendingPathComponent("provenance.json"))
            return ["exact-tested-bytes", "complete-release-inventory", "provenance"]
        }
    }

    func release(_ tag: String, repository selectedRepository: String? = nil) throws -> [String: Any]? {
        try Self.findRelease(tag, repository: selectedRepository ?? repository) { try gh($0) }
    }

    static func findRelease(_ tag: String, repository: String, request: ([String]) throws -> String) throws -> [String: Any]? {
        try require(tag.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil, "Invalid release ID")
        do {
            let json = try request(["api", "repos/\(repository)/releases/tags/\(tag)"])
            guard let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            else { throw BuildError("Invalid GitHub release response") }
            return value
        } catch {
            guard String(describing: error).contains("HTTP 404") else { throw error }
        }
        // The tag endpoint only finds published releases. Authenticated listing also
        // includes drafts, including a new draft whose Git tag does not yet exist.
        let json = try request(["api", "--paginate", "--slurp", "repos/\(repository)/releases?per_page=100"])
        guard let pages = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[[String: Any]]]
        else { throw BuildError("Invalid GitHub release listing") }
        let matches = pages.flatMap(\.self).filter { $0["tag_name"] as? String == tag }
        try require(matches.count <= 1, "Multiple releases have the requested tag")
        return matches.first
    }

    func assets(_ release: [String: Any]) throws -> [String: [String: Any]] {
        guard let values = release["assets"] as? [[String: Any]] else { throw BuildError("Invalid release asset inventory") }
        var result: [String: [String: Any]] = [:]
        for value in values {
            guard let name = value["name"] as? String else { throw BuildError("Asset name missing") }
            try require(result[name] == nil, "Duplicate published asset \(name)")
            result[name] = value
        }
        return result
    }

    func download(_ asset: [String: Any], destination: URL) throws {
        guard let id = asset["id"] as? Int else { throw BuildError("Missing GitHub asset identity") }
        try gh(["api", "-H", "Accept: application/octet-stream", "repos/\(repository)/releases/assets/\(id)"], output: destination)
    }

    func publishArtifacts(_ bundle: URL) throws {
        let index = try read(ArtifactIndex.self, bundle.appendingPathComponent("Artifacts.lock.json"))
        try Generator.validate(index, native: graph.native, release: true)
        try require(
            index.nativeInputFingerprint == Packager(graph: graph).nativeFingerprint(),
            "Candidate build inputs differ from current inputs"
        )
        try require(
            fingerprint(read(NativeLock.self, bundle.appendingPathComponent("Inputs.lock.json"))) == fingerprint(graph.native),
            "Bundled input lock differs from publication inputs"
        )
        try require(
            digest(bundle.appendingPathComponent("RECIPE_LICENSE")) == digest(graph.root.appendingPathComponent("Build/RECIPE_LICENSE")),
            "Bundled recipe license differs from source"
        )
        try require(
            Data(contentsOf: bundle.appendingPathComponent("SOURCE_NOTICES.txt")) == sourceNotices(),
            "Bundled source notices differ from locked sources"
        )
        let provenance = try read(Provenance.self, bundle.appendingPathComponent("provenance.json"))
        let sourceRepository = try sourceRepository()
        try require(
            (provenance.sourceRepository ?? repository) == sourceRepository,
            "Candidate source repository differs from publication checkout"
        )
        try require(
            provenance.schemaVersion == 1 && provenance.nativeInputFingerprint == index.nativeInputFingerprint && provenance
                .artifacts == Dictionary(uniqueKeysWithValues: index.products.map { (
                    $0.archive,
                    $0.sha256
                ) }),
            "Candidate provenance differs from the indexed bytes"
        )
        try require(
            provenance.sourceCommit == graph.runner.run("git", ["rev-parse", "HEAD"], cwd: graph.root),
            "Publication checkout differs from candidate source commit"
        )
        try require(!provenance.sourceWasDirty, "Publication requires a candidate made from committed source")
        try require(
            graph.runner.run("git", ["status", "--porcelain"], cwd: graph.root).isEmpty,
            "Publication requires a clean source checkout"
        )
        // Revalidate the exact bytes and consumers before publication, including cached candidates.
        _ = try ConsumerTests(graph: graph).run(bundle)
        let lock = try FileLock(graph.store.path("locks/publish-\(index.releaseID).lock"))
        defer { withExtendedLifetime(lock) {} }
        let publication = ArtifactPublication(
            release: { try release(index.releaseID) },
            create: {
                let notes = graph.runner.logs.appendingPathComponent("artifact-release-notes.md")
                try put(
                    "MPVBuild build inputs: " + index
                        .nativeInputFingerprint +
                        "\n\nImmutable build artifacts and verification provenance. Package adoption is a separate step.\n",
                    notes
                )
                // A separate artifact repository does not contain the package repository's source commit.
                // Its artifact tag identifies stored assets; provenance retains the actual build repository/commit.
                let target = repository == sourceRepository ? provenance.sourceCommit : try gh([
                    "api",
                    "repos/\(repository)",
                    "--jq",
                    ".default_branch"
                ])
                try gh([
                    "release",
                    "create",
                    index.releaseID,
                    "--repo",
                    repository,
                    "--draft",
                    "--target",
                    target,
                    "--title",
                    index.releaseID,
                    "--notes-file",
                    notes.path
                ])
            },
            upload: { file in _ = try gh(["release", "upload", index.releaseID, file.path, "--repo", repository]) },
            download: { asset, destination in try download(asset, destination: destination) },
            publish: { _ = try gh(["release", "edit", index.releaseID, "--repo", repository, "--draft=false"]) }
        )
        let expected = Self.publishedFiles(index)
        try publication.run(
            bundle: bundle,
            expected: expected,
            marker: "MPVBuild build inputs: " + index.nativeInputFingerprint,
            verification: graph.runner.logs
        )
        print("Published verified artifact release: \(index.releaseID)")
    }

    func adopt(_ id: String, authenticated: Bool = false) throws {
        guard let published = try release(id),
              published["draft"] as? Bool == false else { throw BuildError("Artifact release must already be published") }
        let available = try assets(published)
        guard let indexAsset = available["Artifacts.lock.json"] else { throw BuildError("Published artifact index missing") }
        let stage = graph.runner.logs.appendingPathComponent("adoption-\(UUID().uuidString)")
        try mkdir(stage)
        let indexPath = stage.appendingPathComponent("Artifacts.lock.json")
        try download(indexAsset, destination: indexPath)
        let index = try read(ArtifactIndex.self, indexPath)
        try Generator.validate(index, native: graph.native, release: true)
        try require(
            index.releaseID == id && index.nativeInputFingerprint == Packager(graph: graph).nativeFingerprint(),
            "Published build inputs differ from current lock/recipes"
        )
        try require(
            Set(available.keys) == Set(Self.publishedFiles(index)),
            "Published release must contain one binary ZIP and two lock files"
        )
        guard let nativeAsset = available["Inputs.lock.json"] else { throw BuildError("Published input lock missing") }
        let nativePath = stage.appendingPathComponent("Inputs.lock.json")
        try download(nativeAsset, destination: nativePath)
        try require(fingerprint(read(NativeLock.self, nativePath)) == fingerprint(graph.native), "Published input lock mismatch")
        for artifact in index.products {
            guard let asset = available[artifact.archive] else { throw BuildError("Published artifact missing: \(artifact.archive)") }
            let file = stage.appendingPathComponent(artifact.archive)
            try download(asset, destination: file)
            try require(digest(file) == artifact.sha256, "Published checksum mismatch: \(artifact.archive)")
            let extracted = stage.appendingPathComponent("inspect-" + artifact.target)
            try Archive.extract(file, to: extracted, runner: graph.runner)
            try Packager(graph: graph).verify(
                extracted.appendingPathComponent(artifact.framework + ".xcframework"),
                product: ProductDefinition.all.first { $0.target == artifact.target }!,
                slices: graph.native.slices
            )
            try verifyEmbeddedProvenance(extracted, index: index)
        }
        // Also check unauthenticated consumer URLs, rather than relying on a maintainer's GitHub session.
        // Private GitHub release URLs fail here until a supported authenticated distribution is configured.
        if !authenticated {
            for artifact in index.products {
                try verifyPublicURL(artifact)
            }
        }
        var outputs = try Generator.files(root: graph.root, native: graph.native, index: index)
        outputs["Build/Artifacts.lock.json"] = try canonical(index) + Data([10])
        try Generator.evaluate(outputs["Package.swift"]!, runner: graph.runner)
        if authenticated {
            // Explicit private-repository bootstrap: validate fresh authenticated downloads.
            // This does not claim unauthenticated SwiftPM URLs work before the repo is public.
            _ = try ConsumerTests(graph: graph).run(stage)
        } else {
            try ConsumerTests(graph: graph).validateRemote(index)
        }
        let transaction = try FileTransaction(root: graph.root)
        try transaction.commit(outputs)
        print("Adopted verified artifact release \(id)\(authenticated ? "; authenticated bootstrap, public URL validation pending" : "")")
    }

    func verifyEmbeddedProvenance(_ extracted: URL, index: ArtifactIndex) throws {
        let provenance = try read(NativeBuildProvenance.self, contained(extracted, index.provenancePath))
        try require(
            provenance.schemaVersion == 1 && provenance.nativeInputFingerprint == index.nativeInputFingerprint,
            "Embedded build provenance mismatch"
        )
        try require(provenance.nativeLockDigest == fingerprint(graph.native), "Embedded input lock digest mismatch")
        for slice in index.products[0].slices {
            for arch in slice.architectures {
                let key = slice.id + "/" + arch
                guard let components = provenance.combinedInputs[key] else { throw BuildError("Missing combined library input inventory") }
                let names = ["mpv"] + FFmpegRecipe.libraries + graph.native.dependencies.filter { $0.slices.contains(slice.id) }
                    .flatMap { $0.runtime.map(\.target) }
                try require(Set(components.keys) == Set(names), "Combined library omits library dependencies")
                for sha in components.values {
                    try hex(sha)
                }
            }
        }
        let framework = extracted.appendingPathComponent(index.products[0].framework + ".xcframework")
        try require(
            Data(contentsOf: framework.appendingPathComponent("SOURCE_NOTICES.txt")) == sourceNotices(),
            "Embedded source notices mismatch"
        )
        try require(
            digest(framework.appendingPathComponent("RECIPE_LICENSE")) == digest(graph.root.appendingPathComponent("Build/RECIPE_LICENSE")),
            "Embedded recipe license mismatch"
        )
    }

    func publishPackage(_ tag: String) throws {
        try require(Generator.isVersionTag(tag), "Package tag must be SemVer")
        try require(
            graph.runner.run("git", ["rev-parse", tag + "^{commit}"], cwd: graph.root) == graph.runner.run(
                "git",
                ["rev-parse", "HEAD"],
                cwd: graph.root
            ),
            "Package tag does not identify this checkout"
        )
        try require(graph.runner.run("git", ["status", "--porcelain"], cwd: graph.root).isEmpty, "Tagged package checkout is dirty")
        try Generator.generate(root: graph.root, native: graph.native, runner: graph.runner, check: true)
        let index = try read(ArtifactIndex.self, graph.root.appendingPathComponent("Build/Artifacts.lock.json"))
        for artifact in index.products {
            try verifyPublicURL(artifact)
        }
        try ConsumerTests(graph: graph).validateRemote(index)
        let packageRepository = try sourceRepository()
        if try release(tag, repository: packageRepository) != nil {
            print("Package release already exists: \(tag)")
            return
        }
        let notes = graph.runner.logs.appendingPathComponent("package-release-notes.md")
        try put("MPVUI \(tag)\n\nUses the verified artifact release `\(index.releaseID)`.\n", notes)
        try gh(["release", "create", tag, "--repo", packageRepository, "--verify-tag", "--title", tag, "--notes-file", notes.path])
    }
}
