import Foundation
@testable import MPVBuildCore
import Testing

struct CoreTests {
    func temporary(_ body: (URL) throws -> Void) throws {
        let directory = fm.temporaryDirectory.appendingPathComponent("MPVBuild Tests \(UUID().uuidString)")
        try mkdir(directory)
        defer { try? remove(directory) }
        try body(directory)
    }

    var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func native() throws -> NativeLock {
        try read(NativeLock.self, repository.appendingPathComponent("Build/Inputs.lock.json"))
    }

    @Test
    func `artifact options and legacy aliases`() throws {
        #expect(try Arguments(["check", "--artifacts"]).flags == ["artifacts"])
        #expect(try Arguments(["check", "--native", "--profile", "release"]).flags == ["artifacts"])
        #expect(try Arguments(["test", "--native-only"]).flags == ["artifacts-only"])
        for option in ["--release", "--native"] {
            #expect(try Arguments(["release", "adopt", option, "0.1.0"]).values == ["release": "0.1.0"])
        }
        #expect(throws: (any Error).self) {
            try Arguments(["adopt", "--release"])
        }
        #expect(throws: (any Error).self) {
            try Arguments(["check", "--native", "--artifacts"])
        }
        #expect(throws: (any Error).self) {
            try Arguments(["adopt", "--native", "0.1.0", "--release", "0.1.0"])
        }
    }

    @Test
    func `default store reuses existing cache without moving tools`() throws {
        try temporary { root in
            let current = root.appendingPathComponent(".build/mpvbuild")
            let previous = root.appendingPathComponent(".build/native")
            #expect(CLI.defaultStore(root).path == current.path)
            try mkdir(previous)
            #expect(CLI.defaultStore(root).path == previous.path)
            try mkdir(current)
            #expect(CLI.defaultStore(root).path == current.path)
        }
    }

    @Test
    func `lock formatting does not change fingerprint`() throws {
        let value = try native()
        let pretty = JSONEncoder()
        pretty.outputFormatting = [.prettyPrinted]
        #expect(try fingerprint(value) == fingerprint(decode(NativeLock.self, from: pretty.encode(value))))
    }

    @Test
    func `unknown and missing fields fail`() throws {
        var value = try #require(try JSONSerialization.jsonObject(with: canonical(native())) as? [String: Any])
        value["unexpected"] = true
        #expect(throws: (any Error).self) {
            try decode(NativeLock.self, from: JSONSerialization.data(withJSONObject: value))
        }
        value.removeValue(forKey: "unexpected")
        value.removeValue(forKey: "sourceDateEpoch")
        #expect(throws: (any Error).self) {
            try decode(NativeLock.self, from: JSONSerialization.data(withJSONObject: value))
        }
    }

    @Test
    func `nested unknown field fails`() throws {
        var value = try #require(try JSONSerialization.jsonObject(with: canonical(native())) as? [String: Any])
        var features = try #require(value["features"] as? [String: Any])
        features["hostAutodetect"] = true
        value["features"] = features
        #expect(throws: (any Error).self) {
            try decode(NativeLock.self, from: JSONSerialization.data(withJSONObject: value))
        }
    }

    @Test
    func `lock and patches validate`() throws {
        try native().validate(root: repository)
    }

    @Test
    func `exact selection and release rejection`() throws {
        let lock = try native()
        #expect(try lock.selected(profile: "dev", sliceNames: "ios", archNames: nil, host: "arm64").map(\.id) == ["ios"])
        #expect(throws: (any Error).self) {
            try lock.selected(profile: "release", sliceNames: "ios", archNames: nil, host: "arm64")
        }
        #expect(throws: (any Error).self) {
            try lock.selected(profile: "dev", sliceNames: "xros", archNames: "x86_64", host: "arm64")
        }
        #expect(throws: (any Error).self) {
            try lock.selected(profile: "dev", sliceNames: "ios,ios", archNames: nil, host: "arm64")
        }
        #expect(try lock.selected(profile: "dev", sliceNames: nil, archNames: nil, host: "x86_64").first?.architectures == ["x86_64"])
    }

    @Test
    func `patch order is significant`() throws {
        let patches = try native().source("mpv").patches
        #expect(try fingerprint(patches) != fingerprint(Array(patches.reversed())))
    }

    @Test
    func `MoltenVK selection uses metadata`() throws {
        let slice = try #require(native().slices.first { $0.id == "xrsimulator" })
        let libraries = [XCFLibrary(
            identifier: "xros-arm64_x86_64-simulator",
            libraryPath: "libMoltenVK.a",
            architectures: ["arm64", "x86_64"],
            platform: "xros",
            variant: "simulator"
        )]
        #expect(try XCFLibrary.select(libraries, slice: slice, arch: "arm64").identifier == "xros-arm64_x86_64-simulator")
        #expect(slice.identifier == "xros-arm64-simulator")
        #expect(throws: (any Error).self) {
            try XCFLibrary.select(libraries + libraries, slice: slice, arch: "arm64")
        }
        #expect(throws: (any Error).self) {
            try XCFLibrary.select(libraries, slice: slice, arch: "arm64e")
        }
    }

    @Test
    func `unsafe paths rejected`() throws {
        for path in ["../outside", "/absolute", "a/../../b", "a\\b", "a\nb", "a/./b", "a//b"] {
            #expect(throws: (any Error).self) {
                try Archive.validatePath(path)
            }
        }
        try Archive.validatePath("Libmpv.xcframework/macos-arm64/Libmpv.framework/Versions/A/Headers/client.h")
    }

    @Test
    func `corrupt ZIP and MachO fail`() throws {
        for data in [Data(), Data(repeating: 0, count: 100), Data("!<arch>\ninvalid".utf8)] {
            #expect(throws: (any Error).self) {
                try Archive.entries(data)
            }
            #expect(throws: (any Error).self) {
                try MachO.objects(data)
            }
        }
    }

    @Test
    func `cache verifies bytes and retries failed nodes`() throws {
        try temporary { root in
            let store = try ManagedStore(root: root.appendingPathComponent("native"))
            var builds = 0
            func build(_ directory: URL) throws -> [String] {
                builds += 1
                try put("correct", directory.appendingPathComponent("product"))
                return ["unit"]
            }
            let first = try store.node(stage: "products", name: "fixture", key: "identity", build: build)
            #expect(
                try read(StageRecord.self, first.appendingPathComponent("record.json")).products ==
                    tree(first, excluding: ["record.json"])
            )
            _ = try store.node(stage: "products", name: "fixture", key: "identity", build: build)
            #expect(builds == 1)
            try put("corrupt", first.appendingPathComponent("product"))
            _ = try store.node(stage: "products", name: "fixture", key: "identity", build: build)
            #expect(builds == 2)
            #expect(throws: (any Error).self) {
                try store.node(stage: "products", name: "fails", key: "identity") { output in
                    try put("partial", output.appendingPathComponent("product"))
                    throw BuildError("injected")
                }
            }
            #expect(try !exists(store.path("products/fails/identity/record.json")))
            _ = try store.node(stage: "products", name: "fails", key: "identity", build: build)
            #expect(builds == 3)
        }
    }

    @Test
    func `fresh bypasses products`() throws {
        try temporary { root in
            let store = try ManagedStore(root: root.appendingPathComponent("native"))
            var builds = 0
            for fresh in [false, false, true] {
                _ = try store.node(stage: "products", name: "fixture", key: "identity", fresh: fresh) { directory in builds += 1
                    try put("correct", directory.appendingPathComponent("product"))
                    return ["unit"]
                }
            }
            #expect(builds == 2)
        }
    }

    @Test
    func `dependency identity invalidates cache`() throws {
        try temporary { root in
            let store = try ManagedStore(root: root.appendingPathComponent("native"))
            var builds = 0
            for sha in ["a", "a", "b"] {
                _ = try store.node(
                    stage: "products",
                    name: "fixture",
                    key: "identity",
                    dependencies: ["ffmpeg": sha]
                ) { directory in builds += 1
                    try put("correct", directory.appendingPathComponent("product"))
                    return ["unit"]
                }
            }
            #expect(builds == 2)
        }
    }

    @Test
    func `clean rejects symlink and unowned directories`() throws {
        try temporary { root in
            let target = root.appendingPathComponent("target")
            try mkdir(target)
            try put("keep", target.appendingPathComponent("important"))
            let link = root.appendingPathComponent("alias")
            try fm.createSymbolicLink(at: link, withDestinationURL: target)
            #expect(throws: (any Error).self) {
                try ManagedStore(root: link)
            }
            #expect(throws: (any Error).self) {
                try ManagedStore(root: target)
            }
            #expect(throws: (any Error).self) {
                try contained(root, "../outside")
            }
            #expect(exists(target.appendingPathComponent("important")))
        }
    }

    @Test
    func `process environment and large output`() throws {
        try temporary { root in
            let runner = try Runner(
                developer: "/Applications/Test Xcode.app/Contents/Developer",
                epoch: 1_784_974_019,
                logs: root.appendingPathComponent("logs")
            )
            let output = try runner.run("/usr/bin/env")
            #expect(output.contains("TZ=UTC"))
            #expect(output.contains("ZERO_AR_DATE=1"))
            #expect(output.contains("SOURCE_DATE_EPOCH=1784974019"))
            #expect(output.contains("DEVELOPER_DIR=/Applications/Test Xcode.app/Contents/Developer"))
            #expect(throws: (any Error).self) {
                try runner.run("/usr/bin/true", env: ["DEVELOPER_DIR": "/other"])
            }
            let script = root.appendingPathComponent("large output.sh")
            try put("i=0; while [ $i -lt 20000 ]; do echo standard-output; echo standard-error >&2; i=$((i+1)); done\n", script)
            #expect(try runner.run("/bin/sh", [script.path]).components(separatedBy: "\n").count == 20000)
            #expect(throws: (any Error).self) {
                try runner.run("/bin/sh", ["-c", "echo expected-diagnostic >&2; exit 7"])
            }
        }
    }

    @Test
    func `bootstrapped Meson can reinvoke its entry point`() throws {
        try temporary { root in
            let runner = try Runner(developer: "/test", epoch: 1, logs: root.appendingPathComponent("logs"))
            let modules = root.appendingPathComponent("wheel's modules")
            try put("", modules.appendingPathComponent("mesonbuild/__init__.py"))
            try put("""
            import subprocess, sys
            def main():
                if sys.argv[1:] == ['--internal', 'argument with spaces']:
                    print('internal helper succeeded')
                    return 0
                return subprocess.call([sys.executable, sys.argv[0], '--internal', 'argument with spaces'])
            """, modules.appendingPathComponent("mesonbuild/mesonmain.py"))
            let launcher = root.appendingPathComponent("tool's bin/meson")
            try Bootstrap.installMesonLauncher(python: runner.executable("python3"), modules: modules, destination: launcher)
            #expect(try runner.run(launcher.path, cwd: root) == "internal helper succeeded")
        }
    }

    @Test
    func `job budget and argument errors`() throws {
        #expect(throws: (any Error).self) {
            try Arguments(["build", "--jobs", "0"]).positive("jobs", default: 8)
        }
        #expect(throws: (any Error).self) {
            try Arguments(["build", "--jobs"])
        }
        #expect(throws: (any Error).self) {
            try Arguments(["build", "--unknown"])
        }
        #expect(throws: (any Error).self) {
            try Arguments(["build", "--arch", "arm64", "--arch", "x86_64"])
        }
    }
}
