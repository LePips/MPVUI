import Foundation
@testable import MPVBuildCore
import Testing

struct PublicationTests {
    @Test
    func `draft lookup finds an unpublished tag on a later page`() throws {
        let result = try ReleaseManager.findRelease("artifacts-test", repository: "owner/artifacts") { arguments in
            if arguments.contains("repos/owner/artifacts/releases/tags/artifacts-test") {
                throw BuildError("HTTP 404")
            }
            #expect(arguments.contains("--paginate"))
            #expect(arguments.contains("--slurp"))
            return #"[[{"id":1,"tag_name":"other"}],[{"id":2,"tag_name":"artifacts-test","draft":true}]]"#
        }
        #expect(result?["id"] as? Int == 2)
        #expect(result?["draft"] as? Bool == true)
    }

    @Test
    func `release lookup distinguishes missing from unauthorized`() throws {
        #expect(try ReleaseManager.findRelease("missing", repository: "owner/artifacts") { arguments in
            if arguments.contains("--paginate") {
                return "[[]]"
            }
            throw BuildError("HTTP 404")
        } == nil)
        var requests = 0
        #expect(throws: (any Error).self) {
            try ReleaseManager.findRelease("artifacts-test", repository: "owner/artifacts") { _ in
                requests += 1
                throw BuildError("HTTP 403")
            }
        }
        #expect(requests == 1)
    }

    @Test
    func `release lookup rejects ambiguous drafts`() throws {
        #expect(throws: (any Error).self) {
            try ReleaseManager.findRelease("artifacts-test", repository: "owner/artifacts") { arguments in
                if !arguments.contains("--paginate") {
                    throw BuildError("HTTP 404")
                }
                return #"[[{"tag_name":"artifacts-test","draft":true},{"tag_name":"artifacts-test","draft":true}]]"#
            }
        }
    }

    @Test
    func `package repository comes from origin rather than artifact host`() throws {
        for remote in ["https://github.com/owner/package.git", "git@github.com:owner/package.git", "ssh://git@github.com/owner/package"] {
            #expect(try ReleaseManager.githubRepository(remote) == "owner/package")
        }
        for remote in ["/local/path", "https://example.invalid/owner/package", "https://github.com/owner/package/extra"] {
            #expect(throws: (any Error).self) {
                try ReleaseManager.githubRepository(remote)
            }
        }
    }

    @Test
    func `partial upload resumes and published bytes cannot be overwritten`() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("MPVBuild publication \(UUID().uuidString)")
        try mkdir(root)
        defer { try? remove(root) }
        let bundle = root.appendingPathComponent("bundle")
        let verification = root.appendingPathComponent("verification")
        try put("first immutable bytes", bundle.appendingPathComponent("one.zip"))
        try put("second immutable bytes", bundle.appendingPathComponent("two.zip"))
        let service = FakeReleaseService()
        let publisher = service.publisher()
        service.failUploadNumber = 2
        #expect(throws: (any Error).self) {
            try publisher.run(
                bundle: bundle,
                expected: ["one.zip", "two.zip"],
                marker: service.marker,
                verification: verification
            )
        }
        #expect(service.draft)
        #expect(service.assets.count == 1)
        #expect(service.promotions == 0)
        service.failUploadNumber = nil
        try publisher.run(bundle: bundle, expected: ["one.zip", "two.zip"], marker: service.marker, verification: verification)
        #expect(!service.draft)
        #expect(service.assets.count == 2)
        #expect(service.promotions == 1)
        let uploads = service.uploads
        try publisher.run(bundle: bundle, expected: ["one.zip", "two.zip"], marker: service.marker, verification: verification)
        #expect(service.uploads == uploads)
        #expect(service.promotions == 1)
        try put("different bytes", bundle.appendingPathComponent("one.zip"))
        #expect(throws: (any Error).self) {
            try publisher.run(
                bundle: bundle,
                expected: ["one.zip", "two.zip"],
                marker: service.marker,
                verification: verification
            )
        }
        #expect(service.uploads == uploads)
        #expect(service.assets["one.zip"] == Data("first immutable bytes".utf8))
    }

    @Test
    func `incomplete public release and unowned draft are rejected`() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("MPVBuild publication \(UUID().uuidString)")
        try mkdir(root)
        defer { try? remove(root) }
        try put("bytes", root.appendingPathComponent("asset.zip"))
        let service = FakeReleaseService()
        service.created = true
        service.draft = false
        #expect(throws: (any Error).self) {
            try service.publisher().run(
                bundle: root,
                expected: ["asset.zip"],
                marker: service.marker,
                verification: root.appendingPathComponent("verification")
            )
        }
        #expect(service.uploads == 0)
        service.draft = true
        #expect(throws: (any Error).self) {
            try service.publisher().run(
                bundle: root,
                expected: ["asset.zip"],
                marker: "unrelated identity",
                verification: root.appendingPathComponent("verification")
            )
        }
        #expect(service.uploads == 0)
    }
}

private final class FakeReleaseService {
    let marker = "MPVBuild build inputs: test"
    var created = false
    var draft = true
    var assets: [String: Data] = [:]
    var uploads = 0
    var promotions = 0
    var failUploadNumber: Int?
    func publisher() -> ArtifactPublication {
        ArtifactPublication(release: { [self] in
            created ? ["body": marker, "draft": draft, "assets": assets.keys.sorted().map { ["name": $0] }] : nil
        }, create: { [self] in created = true }, upload: { [self] file in
            uploads += 1
            if uploads == failUploadNumber {
                throw BuildError("injected upload interruption")
            }
            assets[file.lastPathComponent] = try Data(contentsOf: file)
        }, download: { [self] asset, path in
            guard let name = asset["name"] as? String, let bytes = assets[name] else { throw BuildError("missing fake asset") }
            try put(bytes, path)
        }, publish: { [self] in draft = false
            promotions += 1
        })
    }
}
