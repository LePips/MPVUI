import Foundation
@testable import MPVBuildCore
import Testing

struct GenerationTests {
    var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func index() throws -> ArtifactIndex {
        let native = try read(NativeLock.self, root.appendingPathComponent("Build/Inputs.lock.json"))
        let identity = String(repeating: "a", count: 64)
        let release = "artifacts-" + identity
        let products = ProductDefinition.all.map { Artifact(
            target: $0.target,
            framework: $0.framework,
            module: $0.framework,
            archive: $0.archive,
            url: "https://github.com/LePips/MPVUI/releases/download/\(release)/\($0.archive)",
            sha256: String(repeating: "b", count: 64),
            slices: native.slices
        ) }
        return ArtifactIndex(
            schemaVersion: 2,
            releaseID: release,
            nativeInputFingerprint: identity,
            provenancePath: "Libmpv.xcframework/provenance.json",
            products: products,
            dependencies: []
        )
    }

    @Test
    func `remote local remote round trip and idempotence`() throws {
        let original = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let index = try index()
        let remote = try Generator.manifest(original, index: index)
        #expect(try Generator.manifest(remote, index: index) == remote)
        let local = try Generator.manifest(
            remote,
            index: index,
            local: ["Libmpv-GPL": URL(fileURLWithPath: "/tmp/a folder/quote\"/Libmpv.xcframework")],
            packageRoot: URL(fileURLWithPath: "/tmp")
        )
        #expect(local.contains("selection: local"))
        #expect(local.contains("quote\\\""))
        #expect(try Generator.manifest(local, index: index) == remote)
        #expect(remote.contains("name: \"MPVUITests\""))
        #expect(remote.contains("resources: [.copy(\"Resources/Media\")]"))
    }

    @Test
    func `malformed markers are rejected`() throws {
        for original in ["start\nend\nstart\nend", "end\nstart", "start\nmissing", "no markers"] {
            #expect(throws: (any Error).self) {
                try Generator.replace(original, begin: "start", end: "end", body: "replacement")
            }
        }
    }

    @Test
    func `versioned release retains fingerprint and checksums`() throws {
        let original = try index()
        let native = try read(NativeLock.self, root.appendingPathComponent("Build/Inputs.lock.json"))
        #expect(try Generator.releaseID(native: native, fingerprint: original.nativeInputFingerprint, tag: nil) == original.releaseID)
        for tag in ["0.1.0", "v1.2.3", "1.0.0-rc.1"] {
            #expect(try Generator.releaseID(native: native, fingerprint: original.nativeInputFingerprint, tag: tag) == tag)
            let products = original.products.map { product in
                Artifact(
                    target: product.target,
                    framework: product.framework,
                    module: product.module,
                    archive: product.archive,
                    url: "https://github.com/\(native.publication.repository)/releases/download/\(tag)/\(product.archive)",
                    sha256: product.sha256,
                    slices: product.slices
                )
            }
            let versioned = ArtifactIndex(
                schemaVersion: 2,
                releaseID: tag,
                nativeInputFingerprint: original.nativeInputFingerprint,
                provenancePath: original.provenancePath,
                products: products,
                dependencies: []
            )
            try Generator.validate(versioned, native: native, release: true)
            let manifest = try Generator.manifest(
                String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8),
                index: versioned
            )
            #expect(manifest.contains("/releases/download/\(tag)/Libmpv.xcframework.zip"))
            #expect(manifest.contains(original.products[0].sha256))
            let mismatched = ArtifactIndex(
                schemaVersion: 2,
                releaseID: tag,
                nativeInputFingerprint: original.nativeInputFingerprint,
                provenancePath: original.provenancePath,
                products: original.products,
                dependencies: []
            )
            #expect(throws: (any Error).self) {
                try Generator.validate(mismatched, native: native, release: true)
            }
        }
        for tag in ["latest", "../0.1.0", "01.0.0", "0.1", "0.1.0/binary", "native-" + String(repeating: "b", count: 64)] {
            #expect(throws: (any Error).self) {
                try Generator.releaseID(native: native, fingerprint: original.nativeInputFingerprint, tag: tag)
            }
        }
    }

    @Test
    func `release tag separates packaging cache entries`() throws {
        let native = try read(NativeLock.self, root.appendingPathComponent("Build/Inputs.lock.json"))
        func key(_ tag: String) throws -> String {
            try fingerprint(PackagingKey(
                products: [],
                slices: native.slices,
                implementation: "same implementation",
                metadataVersion: native.metadataVersion,
                epoch: native.sourceDateEpoch,
                nativeInputFingerprint: String(repeating: "a", count: 64),
                notices: "same notices",
                license: "same license",
                releaseID: tag
            ))
        }
        #expect(try key("0.1.0") != key("0.2.0"))
    }

    @Test
    func `local binary selection is rejected before first adoption`() throws {
        let remote: [String: Any] = ["targets": [[
            "type": "binary",
            "name": "Libmpv-GPL",
            "url": "https://example.invalid/native.zip",
            "checksum": String(repeating: "a", count: 64)
        ]]]
        try Generator.requireRemoteBinaryTargets(JSONSerialization.data(withJSONObject: remote))
        let local: [String: Any] = ["targets": [["type": "binary", "name": "Libmpv-GPL", "path": ".build/local.xcframework"]]]
        #expect(throws: (any Error).self) {
            try Generator.requireRemoteBinaryTargets(JSONSerialization.data(withJSONObject: local))
        }
    }

    @Test
    func `partial release index is rejected`() throws {
        let index = try index()
        let native = try read(NativeLock.self, root.appendingPathComponent("Build/Inputs.lock.json"))
        try Generator.validate(index, native: native, release: true)
        let product = index.products[0]
        let partial = Artifact(
            target: product.target,
            framework: product.framework,
            module: product.module,
            archive: product.archive,
            url: product.url,
            sha256: product.sha256,
            slices: [native.slices[0]]
        )
        let bad = ArtifactIndex(
            schemaVersion: 2,
            releaseID: index.releaseID,
            nativeInputFingerprint: index.nativeInputFingerprint,
            provenancePath: index.provenancePath,
            products: [partial] + index.products.dropFirst(),
            dependencies: index.dependencies
        )
        #expect(throws: (any Error).self) {
            try Generator.validate(bad, native: native, release: true)
        }
    }

    @Test
    func `combined release has one download and only three published files`() throws {
        let index = try index()
        let native = try read(NativeLock.self, root.appendingPathComponent("Build/Inputs.lock.json"))
        try Generator.validate(index, native: native, release: true)
        #expect(ReleaseManager.publishedFiles(index) == ["Libmpv.xcframework.zip", "Artifacts.lock.json", "Inputs.lock.json"])
        let manifest = try Generator.manifest(
            String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8),
            index: index
        )
        #expect(manifest.components(separatedBy: ".binaryTarget(").count - 1 == 1)
        #expect(!manifest.contains("_FFmpeg-GPL"))
        #expect(!manifest.contains("_MPVKit-GPL"))
        let external = ArtifactIndex(
            schemaVersion: 2,
            releaseID: index.releaseID,
            nativeInputFingerprint: index.nativeInputFingerprint,
            provenancePath: index.provenancePath,
            products: index.products,
            dependencies: [native.dependencies.flatMap(\.runtime)[0]]
        )
        #expect(throws: (any Error).self) {
            try Generator.validate(external, native: native, release: true)
        }
        let multiple = ArtifactIndex(
            schemaVersion: 2,
            releaseID: index.releaseID,
            nativeInputFingerprint: index.nativeInputFingerprint,
            provenancePath: index.provenancePath,
            products: index.products + index.products,
            dependencies: []
        )
        #expect(throws: (any Error).self) {
            try Generator.validate(multiple, native: native, release: true)
        }
    }

    @Test
    func `interrupted transaction restores all old files`() throws {
        let directory = fm.temporaryDirectory.appendingPathComponent("MPVBuildTransaction-\(UUID().uuidString)")
        try mkdir(directory)
        defer { try? remove(directory) }
        let file = directory.appendingPathComponent("first.txt")
        try put("old", file)
        struct Backup: Codable { let path: String
            let existed: Bool
            let contents: Data
        }
        try write(
            [Backup(path: "first.txt", existed: true, contents: Data("old".utf8)), Backup(
                path: "second.txt",
                existed: false,
                contents: Data()
            )],
            directory.appendingPathComponent(".build/mpvbuild-generation-journal.json")
        )
        try put("incomplete new", file)
        try put("incomplete new", directory.appendingPathComponent("second.txt"))
        do { let transaction = try FileTransaction(root: directory)
            withExtendedLifetime(transaction) {}
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "old")
        #expect(!exists(directory.appendingPathComponent("second.txt")))
        #expect(!exists(directory.appendingPathComponent(".build/mpvbuild-generation-journal.json")))
    }
}
