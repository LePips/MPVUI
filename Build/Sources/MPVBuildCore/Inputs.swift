import Foundation

struct InputStore: Sendable {
    let store: ManagedStore
    let runner: Runner
    let root: URL
    let offline: Bool
    var codeRoot: URL {
        ProcessInfo.processInfo.environment["MPVBUILD_CODE_ROOT"].map { URL(fileURLWithPath: $0) } ?? root
            .appendingPathComponent("Build/Sources/MPVBuildCore")
    }

    func archivePath(_ sha: String) throws -> URL {
        try store.path("downloads/\(sha)/\(sha)/archive.zip")
    }

    func gitPath(_ source: Source) throws -> URL {
        try store.path("git/\(hash(Data(source.url.utf8))).git")
    }

    func gitContains(_ source: Source) -> Bool {
        (try? runner.run(
            "git",
            ["--git-dir", gitPath(source).path, "cat-file", "-e", source.commit + "^{commit}"]
        )) != nil
    }

    func preflight(_ lock: NativeLock, slices: [Slice]) throws {
        guard offline else { return }
        var missing: [String] = []
        for source in lock.sources where !gitContains(source) {
            missing.append("git \(source.url) @ \(source.commit)")
        }
        for dependency in lock.dependencies where !Set(dependency.slices).isDisjoint(with: slices.map(\.id)) {
            for (url, sha) in [(dependency.url, dependency.sha256)] + dependency.runtime.map({ ($0.url, $0.sha256) }) {
                if (try? digest(archivePath(sha))) != sha {
                    missing.append("\(sha) \(url)")
                }
            }
        }
        try require(missing.isEmpty, "Offline inputs missing before compilation:\n" + missing.joined(separator: "\n"))
    }

    func fetch(url: String, sha: String, zip: Bool = true) throws -> URL {
        try hex(sha)
        try https(url)
        let result = try store.node(stage: "downloads", name: sha, key: sha) { directory in
            let file = directory.appendingPathComponent("archive.zip")
            // A damaged completion record does not invalidate independently verified download bytes.
            let cached = try archivePath(sha)
            if (try? digest(cached)) == sha {
                try fm.copyItem(at: cached, to: file)
            } else {
                try require(!offline, "Offline archive missing: \(sha) \(url)")
                try runner.run(
                    "/usr/bin/curl",
                    ["--fail", "--location", "--retry", "3", "--proto", "=https", "--proto-redir", "=https", "--output", file.path, url]
                )
            }
            try require(digest(file) == sha, "Download checksum mismatch: \(url)")
            if zip {
                _ = try Archive.entries(Data(contentsOf: file, options: .mappedIfSafe))
            }
            return zip ? ["sha256", "zip-paths"] : ["sha256"]
        }
        return result.appendingPathComponent("archive.zip")
    }

    func extracted(url: String, sha: String) throws -> URL {
        let archive = try fetch(url: url, sha: sha)
        return try store.node(stage: "extracted", name: sha, key: sha) { directory in
            try Archive.extract(archive, to: directory.appendingPathComponent("content"), runner: runner)
            return ["safe-extraction"]
        }.appendingPathComponent("content")
    }

    func prepare(_ source: Source) throws -> URL {
        let repository = try gitPath(source)
        let lock = try FileLock(store.path("locks/git-\(hash(Data(source.url.utf8))).lock"))
        defer { withExtendedLifetime(lock) {} }
        if !gitContains(source) {
            try require(!offline, "Offline Git object missing: \(source.commit)")
            if !exists(repository) {
                try runner.run("git", ["init", "--bare", repository.path])
            }
            try runner.run("git", ["--git-dir", repository.path, "fetch", "--no-tags", "--depth=1", source.url, source.commit])
        }
        struct PreparationKey: Encodable { let source: Source
            let implementation: String
        }
        let key = try fingerprint(PreparationKey(source: source, implementation: digest(codeRoot.appendingPathComponent("Inputs.swift"))))
        return try store.node(stage: "prepared", name: source.id, key: key) { directory in
            let sourceDirectory = directory.appendingPathComponent("source")
            try mkdir(sourceDirectory)
            let archive = directory.appendingPathComponent("source.tar")
            try runner.run("git", ["--git-dir", repository.path, "archive", "--format=tar", source.commit], output: archive)
            try runner.run("/usr/bin/tar", ["-xf", archive.path, "-C", sourceDirectory.path])
            try remove(archive)
            for patch in source.patches {
                let file = try contained(root, patch.path)
                try require(digest(file) == patch.sha256, "Patch changed during preparation")
                // Exported sources have no .git. Prevent Git from discovering the enclosing MPVUI checkout
                // and treating every patch as outside the current subdirectory.
                let environment = ["GIT_CEILING_DIRECTORIES": directory.path]
                try runner.run("git", ["apply", "--check", file.path], cwd: sourceDirectory, env: environment)
                try runner.run("git", ["apply", file.path], cwd: sourceDirectory, env: environment)
            }
            if source.id == "mpv" {
                try put(source.version + "\n", sourceDirectory.appendingPathComponent("MPV_VERSION"))
            }
            if source.id == "ffmpeg" {
                try put(source.version + "\n", sourceDirectory.appendingPathComponent("RELEASE"))
                try put(source.version + "\n", sourceDirectory.appendingPathComponent("VERSION"))
            }
            return ["pinned-commit", "ordered-patches", "locked-version"]
        }.appendingPathComponent("source")
    }

    // Migration/import is explicit. Only checksum-verified downloads and immutable Git objects are imported.
    func seed(from previous: URL, lock native: NativeLock) throws {
        let cache = previous.appendingPathComponent(".build/mpvkit-cache")
        for dependency in native.dependencies {
            for sha in [dependency.sha256] + dependency.runtime.map(\.sha256) {
                let source = cache.appendingPathComponent(sha)
                if !exists(source) {
                    continue
                }
                try require(digest(source) == sha, "Seed checksum mismatch: \(sha)")
                _ = try store.node(stage: "downloads", name: sha, key: sha) { directory in
                    try fm.copyItem(at: source, to: directory.appendingPathComponent("archive.zip"))
                    return ["sha256"]
                }
            }
        }
        for source in native.sources {
            let previousSource = previous
                .appendingPathComponent(".build/mpvkit/dist/\(source.id == "mpv" ? "libmpv" : "FFmpeg")-\(source.ref)")
            if gitContains(source) {
                continue
            }
            let repository = try gitPath(source)
            let lock = try FileLock(store.path("locks/git-\(hash(Data(source.url.utf8))).lock"))
            defer { withExtendedLifetime(lock) {} }
            try runner.run("git", ["-C", previousSource.path, "cat-file", "-e", source.commit + "^{commit}"])
            if !exists(repository) {
                try runner.run("git", ["init", "--bare", repository.path])
            }
            try runner.run("git", ["--git-dir", repository.path, "fetch", "--no-tags", previousSource.path, source.commit])
        }
    }
}
