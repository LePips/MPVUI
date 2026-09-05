import Foundation

struct PackageSelection {
    let graph: BuildGraph
    func local(_ artifact: URL) throws {
        let index = try read(ArtifactIndex.self, artifact.appendingPathComponent("Artifacts.lock.json"))
        try Generator.validate(index, native: graph.native, release: false)
        let paths = try ConsumerTests(graph: graph).materialize(artifact, index: index)
        try select(index, paths: paths)
    }

    func remote() throws {
        try require(!graph.inputs.offline, "Fresh remote package selection requires network access")
        let path = graph.root.appendingPathComponent("Build/Artifacts.lock.json")
        try require(exists(path), "No published artifact release is adopted; remote selection is unavailable")
        let index = try read(ArtifactIndex.self, path)
        try Generator.validate(index, native: graph.native, release: true)
        try select(index, paths: nil)
    }

    private func select(_ index: ArtifactIndex, paths: [String: URL]?) throws {
        let transaction = try FileTransaction(root: graph.root)
        let original = try String(contentsOf: graph.root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let links = try paths.map { try Generator.localLinks($0, package: graph.root, identity: fingerprint(index)) }
        let manifest = try Generator.manifest(original, index: index, local: links, packageRoot: graph.root)
        try Generator.evaluate(Data(manifest.utf8), runner: graph.runner)
        // A distinct scratch path makes SwiftPM evaluate and resolve the new selection without deleting native caches.
        let stage = graph.runner.logs.appendingPathComponent("selection-package")
        try mkdir(stage)
        for name in ["Sources", "Tests", "Vendor"] {
            try fm.createSymbolicLink(at: stage.appendingPathComponent(name), withDestinationURL: graph.root.appendingPathComponent(name))
        }
        let stageLinks = try paths.map { try Generator.localLinks($0, package: stage, identity: fingerprint(index)) }
        let stageManifest = try Generator.manifest(original, index: index, local: stageLinks, packageRoot: stage)
        try put(stageManifest, stage.appendingPathComponent("Package.swift"))
        try graph.runner.run("/usr/bin/swift", ["package", "--package-path", stage.path, "resolve"])
        try transaction.commit(["Package.swift": Data(manifest.utf8)])
        print(
            "Selected \(paths == nil ? "remote" : "local") binary targets; fresh SwiftPM resolution passed. Refresh package resolution in an already-open Xcode workspace."
        )
    }
}
