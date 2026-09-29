import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.integration), .serialized)
@MainActor
struct MPVRenderingCommandTests {
    @Test(arguments: MPVPlayerConfiguration.VideoOutput.allCases)
    func `rendering properties commands and feature requests keep the same client`(
        output: MPVPlayerConfiguration.VideoOutput
    ) async throws {
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: ["ao": "null", "sid": "no"], autoPlay: false,
            hardwareDecoding: .disabled, logLevel: .info, videoOutput: output
        ))
        defer { fixture.close() }
        try await fixture.loadPaused(TestPaths.baselineMedia, at: .seconds(1))
        let player = fixture.player
        let before = await player.lifecycleDiagnostics()
        var completed = false
        player.logHandler = { message in
            if message.message.contains("RENDERING_COMMANDS_COMPLETE") {
                completed = true
            }
        }
        player.setProperty("video-zoom", to: "0.25")
        player.setProperty("brightness", to: "10")
        player.command("add", arguments: ["video-pan-x", "0.1"])
        player.command("vf", arguments: ["add", "hflip"])
        player.command("expand-properties", arguments: ["set", "video-scale-y", "1.1"])
        player.command("print-text", arguments: ["RENDERING_COMMANDS_COMPLETE"])
        try await eventually("rendering commands accepted") { completed }
        let result = player.requestVideoFeatures([.nativeSubtitles, .bakedOverlays, .zoomAndPan])
        #expect(result.outcome == .available)
        let after = await player.lifecycleDiagnostics()
        #expect(player.videoOutput == output)
        #expect(after.handlesCreated == before.handlesCreated)
        #expect(after.handlesDestroyed == before.handlesDestroyed)
        #expect(after.loadCommands == before.loadCommands)
        #expect(player.isPaused)
        #expect(abs(player.position.seconds - 1) < 0.2)
        #expect(player.lastError == nil)
        player.load(TestPaths.baselineMedia, autoPlay: false)
        try await eventually("same backend after another load") { player.state == .paused }
        #expect(player.videoOutput == output)
    }
}
