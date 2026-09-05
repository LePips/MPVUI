import Foundation

struct Updater {
    let graph: BuildGraph
    func run(component: String, ref requested: String?) throws -> URL {
        let id: String
        let ref: String
        if ["mpv", "ffmpeg", "recipes"].contains(component) {
            id = component
            ref = try requested ?? (id == "recipes" ? graph.native.recipeProvenance.ref : graph.native.source(id).ref)
        } else {
            id = component.hasPrefix("n") ? "ffmpeg" : "mpv"
            ref = component
        }
        let url = try id == "recipes" ? graph.native.recipeProvenance.url : graph.native.source(id).url
        try require(!graph.inputs.offline, "Update resolves upstream refs and cannot run offline")
        try require(!ref.hasPrefix("-") && !ref.contains("\n"), "Invalid upstream ref")
        let advertised = try graph.runner.run(
            "git",
            ["ls-remote", url, "refs/tags/" + ref, "refs/tags/" + ref + "^{}", "refs/heads/" + ref]
        )
        let rows = advertised.components(separatedBy: "\n").compactMap { line -> (String, String)? in
            let fields = line.split(separator: "\t")
            return fields.count == 2 ? (String(fields[0]), String(fields[1])) : nil
        }
        let peeled = rows.first { $0.1.hasSuffix("^{}") }
        let matches = peeled.map { [$0] } ?? rows
        try require(matches.count == 1, "Missing or ambiguous upstream ref \(ref)")
        let commit = matches[0].0
        try hex(commit, count: 40)
        let directory = try graph.store.path("updates/\(id)-\(commit)")
        try mkdir(directory)
        if id == "recipes" {
            try put(
                "Upstream recipe resolution\n\nPrevious: \(graph.native.recipeProvenance.commit)\nCandidate: \(commit)\nRef: \(ref)\n\nReview the upstream recipe diff and port relevant changes into Build/Sources/MPVBuildCore/Recipes. Inputs.lock.json is not promoted automatically.\n",
                directory.appendingPathComponent("REVIEW.md")
            )
            let source = Source(id: "recipes", url: url, ref: ref, commit: commit, version: ref, patches: [])
            let prepared = try graph.inputs.prepare(source)
            for name in ["base.swift", "main.swift"] {
                try fm.copyItem(
                    at: prepared.appendingPathComponent("Sources/BuildScripts/XCFrameworkBuild/" + name),
                    to: directory.appendingPathComponent("upstream-" + name)
                )
            }
            return directory
        }
        var object = try JSONSerialization.jsonObject(with: canonical(graph.native)) as! [String: Any]
        var sources = object["sources"] as! [[String: Any]]
        let position = sources.firstIndex { $0["id"] as? String == id }!
        let previous = sources[position]["commit"] as! String
        sources[position]["commit"] = commit
        sources[position]["ref"] = ref
        sources[position]["version"] = ref.hasPrefix("v") || ref.hasPrefix("n") ? String(ref.dropFirst()) : ref
        object["sources"] = sources
        let candidate = try decode(NativeLock.self, from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        try candidate.validate(root: graph.root)
        _ = try graph.inputs.prepare(candidate.source(id))
        try write(candidate, directory.appendingPathComponent("Inputs.lock.json"))
        try put(
            "Build input update candidate\n\nComponent: \(id)\nRef: \(ref)\nPrevious commit: \(previous)\nCandidate commit: \(commit)\nOrdered patches: applied and verified.\n\nReview this lock and run a complete release candidate before adoption. The committed lock and manifests were not modified.\n",
            directory.appendingPathComponent("REVIEW.md")
        )
        return directory
    }
}
