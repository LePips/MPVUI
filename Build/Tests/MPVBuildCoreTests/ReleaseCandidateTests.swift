import Foundation
@testable import MPVBuildCore
import Testing

struct ReleaseCandidateTests {

    @Test
    func `release simulator overrides select only the requested platform destinations`() throws {
        let inventory = [
            ConsumerTests.Simulator(id: "ios-new", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1", state: "Booted"),
            ConsumerTests.Simulator(id: "ios-phone", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-0", state: "Shutdown"),
            ConsumerTests.Simulator(id: "tv", runtime: "com.apple.CoreSimulator.SimRuntime.tvOS-26-5", state: "Shutdown"),
        ]

        #expect(try ConsumerTests.selectSimulators(inventory, environment: [:]).map(\.id) == ["ios-new", "ios-phone", "tv"])
        #expect(try ConsumerTests.selectSimulators(inventory, environment: ["MPVUI_IOS_SIMULATOR": "ios-phone"]).map(\.id) == [
            "ios-phone",
            "tv",
        ])

        for overrides in [["MPVUI_IOS_SIMULATOR": "missing"], ["MPVUI_IOS_SIMULATOR": "tv"], ["MPVUI_TVOS_SIMULATOR": "ios-phone"]] {
            #expect(throws: BuildError.self) {
                try ConsumerTests.selectSimulators(inventory, environment: overrides)
            }
        }
    }

    @Test
    func `playback validation rejects locked or inactive desktop sessions`() throws {
        let session: [String: Any] = [
            "kCGSSessionUserNameKey": "tester",
            "kCGSSessionOnConsoleKey": true,
            "kCGSessionLoginDoneKey": true,
        ]
        try ConsumerTests.validateConsoleSession(["IOConsoleUsers": [session]], user: "tester")

        for properties: [String: Any] in [
            [:],
            ["IOConsoleUsers": [session], "IOConsoleLocked": true],
            ["IOConsoleUsers": [session.merging(["CGSSessionScreenIsLocked": true]) { _, new in new }]],
            ["IOConsoleUsers": [session.merging(["kCGSSessionOnConsoleKey": false]) { _, new in new }]],
            ["IOConsoleUsers": [session.merging(["kCGSSessionUserNameKey": "other"]) { _, new in new }]],
        ] {
            #expect(throws: BuildError.self) {
                try ConsumerTests.validateConsoleSession(properties, user: "tester")
            }
        }
    }

    @Test
    func `reusing a candidate requires the current inputs and requested version`() throws {
        let native = try lock()
        let fingerprint = String(repeating: "a", count: 64)
        let index = candidate(native: native, fingerprint: fingerprint)
        try ReleaseManager.validateCandidate(index, native: native, fingerprint: fingerprint, tag: "0.7.0")
        try ReleaseManager.validateCandidate(index, native: native, fingerprint: fingerprint, tag: nil)

        #expect(throws: BuildError.self) {
            try ReleaseManager.validateCandidate(index, native: native, fingerprint: String(repeating: "b", count: 64), tag: nil)
        }

        #expect(throws: BuildError.self) {
            try ReleaseManager.validateCandidate(index, native: native, fingerprint: fingerprint, tag: "0.8.0")
        }
    }

    @Test
    func `a development slice cannot be reused as a release candidate`() throws {
        let native = try lock()
        let fingerprint = String(repeating: "a", count: 64)
        let index = candidate(native: native, fingerprint: fingerprint, slices: [native.apple.slices[0]])

        #expect(throws: BuildError.self) {
            try ReleaseManager.validateCandidate(index, native: native, fingerprint: fingerprint, tag: nil)
        }
    }

    private func candidate(native: NativeLock, fingerprint: String, slices: [Slice]? = nil) -> ArtifactIndex {
        ArtifactIndex(
            releaseID: "0.7.0",
            nativeInputFingerprint: fingerprint,
            buildRecordPath: "Libmpv.xcframework/build-record.json",
            products: [Artifact(
                target: "Libmpv-GPL",
                framework: "Libmpv",
                module: "Libmpv",
                archive: "Libmpv.xcframework.zip",
                url: "https://github.com/\(native.apple.publication.repository)/releases/download/0.7.0/Libmpv.xcframework.zip",
                sha256: String(repeating: "c", count: 64),
                slices: slices ?? native.apple.slices
            )],
            dependencies: []
        )
    }

    private func lock() throws -> NativeLock {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        return try JSONDecoder().decode(NativeLock.self, from: Data(contentsOf: root.appendingPathComponent("Build/Inputs.lock.json")))
    }
}
