import Foundation
@testable import MPVBuildCore
import Testing

/// Registration integrity only. Production HDR/Dolby behavior is exercised by
/// the sanitizer harness in Build/Tests/NativeHDR, not by this lock-file check.
struct NativePatchRegistrationTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func lock() throws -> NativeLock {
        try JSONDecoder().decode(NativeLock.self, from: Data(contentsOf: root.appendingPathComponent("Build/Inputs.lock.json")))
    }

    @Test
    func `registered native patches match their locked bytes`() throws {
        try lock().validate(root: root)
    }

    @Test(arguments: ["mpv", "ffmpeg"])
    func `changed patch bytes are rejected before building`(source: String) throws {
        let lock = try lock()
        let fixture = try copiedPatchTree()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let patch = try #require(lock.source(source).patches.first)
        let path = fixture.appendingPathComponent(patch.path)
        var bytes = try Data(contentsOf: path)
        bytes.append(contentsOf: "\nchanged\n".utf8)
        try bytes.write(to: path)

        do {
            try lock.validate(root: fixture)
            Issue.record("Modified patch bytes were accepted")
        } catch let error as BuildError {
            #expect(error.description == "Patch checksum drift: \(patch.path)")
        }
    }

    @Test(arguments: ["mpv", "ffmpeg"])
    func `unregistered patches are rejected rather than silently omitted`(source: String) throws {
        let lock = try lock()
        let fixture = try copiedPatchTree()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Data("unregistered patch".utf8).write(to: fixture.appendingPathComponent("Build/Patches/\(source)/unregistered.patch"))

        do {
            try lock.validate(root: fixture)
            Issue.record("An unregistered patch was accepted")
        } catch let error as BuildError {
            #expect(error.description == "Missing or unexpected \(source) patches")
        }
    }

    private func copiedPatchTree() throws -> URL {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("native-patch-tests-\(UUID())")
        do {
            try FileManager.default.createDirectory(at: fixture.appendingPathComponent("Build"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: root.appendingPathComponent("Build/Patches"),
                to: fixture.appendingPathComponent("Build/Patches")
            )
            return fixture
        } catch {
            try? FileManager.default.removeItem(at: fixture)
            throw error
        }
    }
}
