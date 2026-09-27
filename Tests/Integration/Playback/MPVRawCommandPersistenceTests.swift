import Foundation
import Libmpv
@testable import MPVUI
import Testing

@Suite(.tags(.integration), .serialized)
@MainActor
struct MPVRawCommandPersistenceTests {
    private nonisolated static var outputs: [MPVPlayerConfiguration.VideoOutput] {
        #if targetEnvironment(simulator)
        // Metal Simulator cannot allocate libplacebo's staging buffer for the
        // negative-stride software hflip output. The engine restore path is
        // also exercised by native output here and both outputs on devices.
        [.sampleBuffer]
        #else
        MPVPlayerConfiguration.VideoOutput.allCases
        #endif
    }

    @Test(arguments: outputs)
    func `raw geometry and filters survive repeated stop replay without compounding mutations`(
        output: MPVPlayerConfiguration.VideoOutput
    ) async throws {
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: ["ao": "null"], autoPlay: false,
            hardwareDecoding: .disabled, logLevel: .info, videoOutput: output
        ))
        defer { fixture.close() }
        try await fixture.loadPaused()
        let player = fixture.player
        player.command("set", arguments: ["video-rotate", "90"])
        player.command("add", arguments: ["options/video-zoom", "0.25"])
        player.command("vf", arguments: ["add", "@flip:hflip"])
        let before = try await runtimeSettings(player)
        #expect(before.contains("rotation=90"))
        #expect(before.contains("zoom=0.250000"))
        #expect(before.contains("hflip"))
        for _ in 0 ..< 2 {
            player.stop()
            try await eventually("raw-configured playback stopped") { player.state == .stopped }
            player.play()
            try await eventually("raw-configured playback replayed from zero") {
                player.state == .playing && player.position.seconds < 1
            }
            player.pause()
            try await eventually("raw-configured replay paused") { player.state == .paused }
            #expect(try await runtimeSettings(player) == before)
            #expect(player.lastError == nil)
        }
        // A property API update while no client exists must supersede the
        // earlier raw command snapshot even when using the options/ alias.
        player.stop()
        try await eventually("stopped before deferred property") { player.state == .stopped }
        player.setProperty("options/video-zoom", to: "0.5")
        player.play()
        try await eventually("replayed after deferred property") { player.state == .playing }
        #expect(try await runtimeSettings(player).contains("zoom=0.500000"))
        #expect(player.lastError == nil)
    }

    @Test
    func `timeline file local and rejected mutations are not restored as configuration`() {
        let engine = MPVEngine(configuration: .init()) { _ in }
        defer { engine.shutdownSynchronously() }
        engine.queue.sync {
            for property in ["pause", "wid", "vo", "file-local-options/video-zoom", "start"] {
                engine.recordAcceptedCommand(["set", property, "1"], status: 0)
            }
            engine.recordAcceptedCommand(["set", "video-rotate", "invalid"], status: MPV_ERROR_COMMAND.rawValue)
            #expect(engine.commandMutatedOptions.isEmpty)
            engine.recordAcceptedCommand(["set", "chapter", "1"], status: 0)
            engine.recordAcceptedCommand(["set", "time-pos", "1"], status: 0)
            #expect(engine.commandMutatedOptions.isEmpty)
        }
    }

    private func runtimeSettings(_ player: MPVPlayer) async throws -> String {
        var result: String?
        player.logHandler = { message in
            if let marker = message.message.range(of: "RAW_RENDER ") {
                result = String(message.message[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        player.command("expand-properties", arguments: [
            "print-text", "RAW_RENDER rotation=${=video-rotate} zoom=${=video-zoom} filters=${=vf}",
        ])
        try await eventually("native raw rendering settings") { result != nil }
        return try #require(result)
    }
}
