import Foundation
@testable import MPVBuildCore
import Testing

/// Registration integrity only. Production HDR/Dolby behavior is exercised by
/// the sanitizer harness in Build/Tests/NativeHDR, not by this lock-file check.
struct NativePatchRegistrationTests {

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test
    func `registered native patches match their locked bytes`() throws {
        try lock().validate(root: root)
    }

    @Test
    func `encoding the shared lock preserves both platform sections`() throws {
        let original = try Data(contentsOf: root.appendingPathComponent("Build/Inputs.lock.json"))

        let before = try #require(JSONSerialization.jsonObject(with: original) as? NSDictionary)
        let after = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(lock())) as? NSDictionary)
        #expect(before == after)
    }

    @Test
    func `Apple build inputs exclude Android changes`() throws {
        let native = try lock()

        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(native)) as? [String: Any])
        var android = try #require(object["android"] as? [String: Any])
        android["recipe"] = String(repeating: "a", count: 40)
        object["android"] = android
        let changed = try JSONDecoder().decode(NativeLock.self, from: JSONSerialization.data(withJSONObject: object))

        #expect(try fingerprint(native.appleBuildInputs) == fingerprint(changed.appleBuildInputs))
        #expect(try fingerprint(native) != fingerprint(changed))
        #expect(try native.source("ffmpeg").patches.allSatisfy { !$0.path.hasPrefix("Build/Android/") })
        #expect(try native.source("ffmpeg", platform: .android).patches.allSatisfy { $0.path.hasPrefix("Build/Android/") })
    }

    @Test(arguments: ["mpv", "ffmpeg", "libplacebo"])
    func `changed patch bytes are rejected before building`(source: String) throws {
        let lock = try lock()
        let fixture = try copiedPatchTree()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let patches = source == "libplacebo" ? lock.android.git[source]?.patches ?? [] : try lock.source(source).patches

        let patch = try #require(patches.first)
        let path = fixture.appendingPathComponent(patch.path)
        var bytes = try Data(contentsOf: path)
        bytes.append(contentsOf: "\nchanged\n".utf8)
        try bytes.write(to: path)

        do {
            try lock.validate(root: fixture)

            Issue.record("Modified patch bytes were accepted")
        } catch let error as BuildError {
            #expect(error.localizedDescription == "Patch checksum drift: \(patch.path)")
        }
    }

    @Test(arguments: ["mpv", "ffmpeg", "Android"])
    func `unregistered patches are rejected rather than silently omitted`(source: String) throws {
        let lock = try lock()
        let fixture = try copiedPatchTree()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let directory = source == "Android" ? "Build/Android/Patches" : "Build/Patches/\(source)"
        try Data("unregistered patch".utf8).write(to: fixture.appendingPathComponent("\(directory)/unregistered.patch"))

        do {
            try lock.validate(root: fixture)

            Issue.record("An unregistered patch was accepted")
        } catch let error as BuildError {
            #expect(error.localizedDescription == "Missing or unexpected \(source) patches")
        }
    }

    private func lock() throws -> NativeLock {
        try JSONDecoder().decode(NativeLock.self, from: Data(contentsOf: root.appendingPathComponent("Build/Inputs.lock.json")))
    }

    private func copiedPatchTree() throws -> URL {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("native-patch-tests-\(UUID())")
        do {
            try FileManager.default.createDirectory(at: fixture.appendingPathComponent("Build"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: root.appendingPathComponent("Build/Patches"),
                to: fixture.appendingPathComponent("Build/Patches")
            )
            try FileManager.default.createDirectory(at: fixture.appendingPathComponent("Build/Android"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: root.appendingPathComponent("Build/Android/Patches"),
                to: fixture.appendingPathComponent("Build/Android/Patches")
            )
            return fixture
        } catch {
            try? FileManager.default.removeItem(at: fixture)
            throw error
        }
    }
}
