import Foundation
@testable import MPVBuildCore
import Testing

struct FailureTests {
    func temporary(_ body: (URL) throws -> Void) throws {
        let root = fm.temporaryDirectory.appendingPathComponent("MPVBuild failure tests \(UUID().uuidString)").resolvingSymlinksInPath()
        try mkdir(root)
        defer { try? remove(root) }
        try body(root)
    }

    var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test
    func `concurrent cache writers produce one complete product`() throws {
        try temporary { root in
            let store = try ManagedStore(root: root.appendingPathComponent("store"))
            let counter = ConcurrentResult()
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                do {
                    _ = try store.node(stage: "products", name: "same", key: "same") { output in
                        counter.increment()
                        try put(Data(repeating: 42, count: 2_000_000), output.appendingPathComponent("binary"))
                        return ["complete"]
                    }
                } catch { counter.fail(error) }
            }
            #expect(counter.count == 1)
            #expect(counter.errors == [])
            let output = try store.path("products/same/same")
            #expect(try read(StageRecord.self, output.appendingPathComponent("record.json")).verify(
                output,
                stage: "products",
                key: "same",
                dependencies: [:]
            ))
        }
    }

    @Test
    func `corrupt download record repairs offline from verified bytes`() throws {
        try temporary { root in
            let store = try ManagedStore(root: root.appendingPathComponent("store"))
            let runner = try Runner(developer: "/test", epoch: 1, logs: root.appendingPathComponent("logs"))
            let inputs = InputStore(store: store, runner: runner, root: repository, offline: true)
            let bytes = Data("checksum-locked input".utf8)
            let sha = MPVBuildCore.hash(bytes)
            let archive = try inputs.archivePath(sha)
            try put(bytes, archive)
            try put("broken record", archive.deletingLastPathComponent().appendingPathComponent("record.json"))
            #expect(try Data(contentsOf: inputs.fetch(url: "https://example.invalid/input.tar", sha: sha, zip: false)) == bytes)
            try put("corrupted bytes", archive)
            #expect(throws: (any Error).self) {
                try inputs.fetch(url: "https://example.invalid/input.tar", sha: sha, zip: false)
            }
        }
    }

    @Test
    func `immutable cache clone keeps atomic repairs isolated`() throws {
        try temporary { root in
            let source = root.appendingPathComponent("input")
            let clone = root.appendingPathComponent("clone")
            try put("verified original", source.appendingPathComponent("directory/archive"))
            try fm.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "directory/archive")
            try Reproducibility.copyImmutableCache(source, to: clone)
            #expect(try tree(source) == tree(clone))
            try put("replacement", clone.appendingPathComponent("directory/archive"))
            #expect(try String(contentsOf: source.appendingPathComponent("link"), encoding: .utf8) == "verified original")
            #expect(try String(contentsOf: clone.appendingPathComponent("link"), encoding: .utf8) == "replacement")
        }
    }

    @Test
    func `audit checkout contains build inputs without package caches`() throws {
        try temporary { root in
            let native = try read(NativeLock.self, repository.appendingPathComponent("Build/Inputs.lock.json"))
            let store = try ManagedStore(root: root.appendingPathComponent("store"))
            let runner = try Runner(developer: "/test", epoch: 1, logs: root.appendingPathComponent("logs"))
            let graph = BuildGraph(
                root: repository,
                native: native,
                store: store,
                runner: runner,
                inputs: InputStore(store: store, runner: runner, root: repository, offline: true)
            )
            let checkout = root.appendingPathComponent("different/deeper checkout")
            try Reproducibility(graph: graph).stageCheckout(at: checkout)
            let copied = try read(NativeLock.self, checkout.appendingPathComponent("Build/Inputs.lock.json"))
            try copied.validate(root: checkout)
            #expect(try fingerprint(copied) == fingerprint(native))
            #expect(try tree(graph.codeRoot) == tree(checkout.appendingPathComponent("Build/Sources/MPVBuildCore")))
            #expect(
                try digest(repository.appendingPathComponent("Package.swift")) ==
                    digest(checkout.appendingPathComponent("Package.swift"))
            )
            #expect(fm.isExecutableFile(atPath: checkout.appendingPathComponent("Build/mpvbuild").path))
            #expect(exists(checkout.appendingPathComponent("Build/Tests/MPVBuildCoreTests/CoreTests.swift")))
            #expect(exists(checkout.appendingPathComponent("Tests/Resources/Fixtures.lock.json")))
            #expect(!exists(checkout.appendingPathComponent("Build/.build")))
            #expect(!exists(checkout.appendingPathComponent(".build")))
        }
    }

    @Test
    func `archive rejects escape and preserves framework symlinks`() throws {
        try temporary { root in
            let runner = try Runner(developer: "/test", epoch: 1, logs: root.appendingPathComponent("logs"))
            let source = root.appendingPathComponent("source")
            try mkdir(source.appendingPathComponent("Framework/Versions/A"))
            try put("binary", source.appendingPathComponent("Framework/Versions/A/Binary"))
            try fm.createSymbolicLink(atPath: source.appendingPathComponent("Framework/Versions/Current").path, withDestinationPath: "A")
            try fm.createSymbolicLink(
                atPath: source.appendingPathComponent("Framework/Binary").path,
                withDestinationPath: "Versions/Current/Binary"
            )
            let archive = root.appendingPathComponent("valid.zip")
            try runner.run("/usr/bin/zip", ["-qry", archive.path, "Framework"], cwd: source)
            let output = root.appendingPathComponent("valid")
            try Archive.extract(archive, to: output, runner: runner)
            #expect(try tree(source) == tree(output))
            try fm.createSymbolicLink(atPath: source.appendingPathComponent("escape").path, withDestinationPath: "../../outside")
            let unsafe = root.appendingPathComponent("unsafe.zip")
            try runner.run("/usr/bin/zip", ["-qy", unsafe.path, "escape"], cwd: source)
            #expect(throws: (any Error).self) {
                try Archive.extract(unsafe, to: root.appendingPathComponent("unsafe"), runner: runner)
            }
            #expect(!exists(root.appendingPathComponent("unsafe")))
            #expect(throws: (any Error).self) {
                try Archive.extract(archive, to: source, runner: runner)
            }
        }
    }

    @Test
    func `MPV only code and generated outputs do not invalidate FFmpeg`() throws {
        try temporary { root in
            let code = root.appendingPathComponent("Build/Sources/MPVBuildCore")
            try put("ffmpeg recipe", code.appendingPathComponent("Recipes/NativeRecipe.swift"))
            try put("mpv recipe 1", code.appendingPathComponent("Recipes/MPVRecipe.swift"))
            try mkdir(root.appendingPathComponent("Build/Support"))
            let native = try read(NativeLock.self, repository.appendingPathComponent("Build/Inputs.lock.json"))
            let store = try ManagedStore(root: root.appendingPathComponent("store"))
            let runner = try Runner(developer: "/test", epoch: 1, logs: root.appendingPathComponent("logs"))
            let graph = BuildGraph(
                root: root,
                native: native,
                store: store,
                runner: runner,
                inputs: InputStore(store: store, runner: runner, root: root, offline: true)
            )
            let ff = try graph.implementation(component: "ffmpeg")
            let mpv = try graph.implementation(component: "mpv")
            try put("mpv recipe 2", code.appendingPathComponent("Recipes/MPVRecipe.swift"))
            #expect(try ff == graph.implementation(component: "ffmpeg"))
            #expect(try mpv != graph.implementation(component: "mpv"))
            let identity = try Packager(graph: graph).nativeFingerprint()
            try put("new generated checksum", root.appendingPathComponent("Build/Artifacts.lock.json"))
            try put("new wrapper", root.appendingPathComponent("Sources/Wrapper.swift"))
            try put("new test", code.appendingPathComponent("ConsumerTests.swift"))
            #expect(try identity == Packager(graph: graph).nativeFingerprint())
        }
    }

    @Test
    func `audit measures CPU and resident memory with Apple time`() throws {
        try temporary { root in
            let runner = try Runner(developer: "/test", epoch: 1, logs: root.appendingPathComponent("logs"))
            let output = try runner.run("/usr/bin/time", ["-lp", "/usr/bin/true"], combined: true)
            let resources = try Reproducibility.Resources.parse(output)
            #expect(resources.userCPUSeconds >= 0)
            #expect(resources.maximumResidentBytes > 0)
            #expect(throws: (any Error).self) {
                try Reproducibility.Resources.parse("missing measurements")
            }
        }
    }

    @Test
    func `Apple metadata ordering does not change archive inputs`() throws {
        try temporary { root in
            let a: [String: Any] = [
                "LibraryIdentifier": "ios-arm64_x86_64-simulator",
                "SupportedArchitectures": ["x86_64", "arm64"],
                "LibraryPath": "Libmpv.framework"
            ]
            let b: [String: Any] = [
                "LibraryIdentifier": "ios-arm64",
                "SupportedArchitectures": ["arm64"],
                "LibraryPath": "Libmpv.framework"
            ]
            let first = root.appendingPathComponent("first.plist")
            let second = root.appendingPathComponent("second.plist")
            for (file, libraries) in [(first, [a, b]), (second, [b, a])] {
                try put(
                    PropertyListSerialization
                        .data(
                            fromPropertyList: ["AvailableLibraries": libraries, "XCFrameworkFormatVersion": "1.0"],
                            format: .xml,
                            options: 0
                        ),
                    file
                )
                try Packager.normalizeMetadata(file)
            }
            #expect(try Data(contentsOf: first) == Data(contentsOf: second))
            let once = try Data(contentsOf: first)
            try Packager.normalizeMetadata(first)
            #expect(try once == Data(contentsOf: first))
            let libraries = try #require(plist(first)["AvailableLibraries"] as? [[String: Any]])
            #expect(libraries.last?["SupportedArchitectures"] as? [String] == ["arm64", "x86_64"])
        }
    }
}

private final class ConcurrentResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var failures: [String] = []
    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func fail(_ error: Error) {
        lock.lock()
        failures.append(String(describing: error))
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    var errors: [String] {
        lock.lock()
        defer { lock.unlock() }
        return failures
    }
}
