import Foundation
@testable import MPVBuildCore
import Testing

struct NativeArchitectureTests {

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test(arguments: ["ios", "isimulator", "maccatalyst", "macos", "tvos", "tvsimulator", "xros", "xrsimulator"])
    func `unadopted arm64e build inputs are rejected`(platform: String) throws {
        let data = try Data(contentsOf: root.appendingPathComponent("Build/Inputs.lock.json"))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var apple = try #require(object["apple"] as? [String: Any])
        var slices = try #require(apple["slices"] as? [[String: Any]])
        let index = try #require(slices.firstIndex { $0["id"] as? String == platform })
        var architectures = try #require(slices[index]["architectures"] as? [String])
        architectures.append("arm64e")
        slices[index]["architectures"] = architectures
        apple["slices"] = slices
        object["apple"] = apple

        let lock = try JSONDecoder().decode(NativeLock.self, from: JSONSerialization.data(withJSONObject: object))

        do {
            try lock.validate(root: root)
            Issue.record("Unadopted arm64e input was accepted for \(platform)")
        } catch let error as BuildError {
            #expect(error.description == "Unsupported architectures for \(platform)")
        }
    }

    @Test
    func `binary inventory rejects an undeclared arm64e slice`() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let binary = directory.appendingPathComponent("Libmpv")
        let tvos = try slice("tvos")
        try universal([("arm64", 3), ("arm64e", 3)]).write(to: binary)

        // Selecting the declared architecture alone misses the extra binary slice.
        _ = try MachO.validate(binary, slice: tvos, arch: "arm64", allowOtherArchitectures: true)
        #expect(throws: BuildError.self) { try MachO.validate(binary, slice: tvos) }

        try thin("arm64", platform: 3).write(to: binary)
        try MachO.validate(binary, slice: tvos)
    }

    @Test
    func `binary inventory requires every declared architecture and its platform`() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let binary = directory.appendingPathComponent("Libmpv")
        let simulator = try slice("tvsimulator")

        try thin("arm64", platform: 8).write(to: binary)
        #expect(throws: BuildError.self) { try MachO.validate(binary, slice: simulator) }

        try universal([("arm64", 8), ("x86_64", 7)]).write(to: binary)
        #expect(throws: BuildError.self) { try MachO.validate(binary, slice: simulator) }

        try universal([("arm64", 8), ("x86_64", 8)]).write(to: binary)
        try MachO.validate(binary, slice: simulator)
    }

    @Test(arguments: ["ios", "tvos", "macos"])
    func `consumer archives validate the embedded framework bytes`(platform: String) throws {
        let archive = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: archive) }

        let native = try slice(platform)

        let info: [String: Any] = [
            "ApplicationProperties": ["ApplicationPath": "Applications/Consumer.app", "Architectures": native.architectures]
        ]

        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: archive.appendingPathComponent("Info.plist"))

        let frameworks = platform == "macos" ? "Contents/Frameworks" : "Frameworks"
        let framework = archive.appendingPathComponent("Products/Applications/Consumer.app/\(frameworks)/Libmpv.framework")
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)

        let binary = framework.appendingPathComponent("Libmpv")
        let architectures = native.architectures.map { ($0, native.machOPlatform) }

        try universal(architectures + [("arm64e", native.machOPlatform)]).write(to: binary)
        #expect(throws: BuildError.self) { try ConsumerTests.validateArchive(archive, slice: native) }

        try universal(architectures).write(to: binary)
        try ConsumerTests.validateArchive(archive, slice: native)
    }

    private func slice(_ id: String) throws -> Slice {
        let lock = try JSONDecoder().decode(NativeLock.self, from: Data(contentsOf: root.appendingPathComponent("Build/Inputs.lock.json")))
        return try #require(lock.apple.slices.first { $0.id == id })
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-architecture-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func thin(_ architecture: String, platform: Int) -> Data {
        words([
            0xFEED_FACF,
            architecture == "x86_64" ? 0x0100_0007 : 0x0100_000C,
            architecture == "arm64e" ? 0x8000_0002 : architecture == "x86_64" ? 3 : 0,
            6,
            1,
            24,
            0,
            0,
            0x32,
            24,
            UInt32(platform),
            (platform == 1 ? 13 : 16) << 16,
            27 << 16,
            0,
        ])
    }

    private func universal(_ architectures: [(String, Int)]) -> Data {
        if architectures.count == 1 {
            return thin(architectures[0].0, platform: architectures[0].1)
        }

        var header: [UInt32] = [0xCAFE_BABE, UInt32(architectures.count)]
        var bodies = Data()

        for (architecture, platform) in architectures {
            let binary = thin(architecture, platform: platform)

            header += [
                architecture == "x86_64" ? 0x0100_0007 : 0x0100_000C,
                architecture == "arm64e" ? 0x8000_0002 : architecture == "x86_64" ? 3 : 0,
                UInt32(8 + architectures.count * 20 + bodies.count),
                UInt32(binary.count),
                0,
            ]

            bodies.append(binary)
        }

        return words(header, bigEndian: true) + bodies
    }

    private func words(_ values: [UInt32], bigEndian: Bool = false) -> Data {
        Data(values.flatMap { value in
            (0 ..< 4).map { UInt8(truncatingIfNeeded: value >> (8 * (bigEndian ? 3 - $0 : $0))) }
        })
    }
}
