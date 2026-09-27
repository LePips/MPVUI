import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.integration), .serialized)
@MainActor
struct MPVStoppedRawCommandTests {
    @Test(arguments: MPVPlayerConfiguration.VideoOutput.allCases)
    func `explicit raw commands while stopped preserve native ordering without starting media`(
        output: MPVPlayerConfiguration.VideoOutput
    ) async throws {
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: ["ao": "null"], autoPlay: false, videoOutput: output
        ))
        defer { fixture.close() }
        try await fixture.loadPaused()
        let player = fixture.player
        player.stop()
        try await eventually("stopped native client") { player.state == .stopped }
        let stopped = await player.lifecycleDiagnostics()
        player.setVolume(25)
        player.command("add", arguments: ["volume", "12"])
        player.setMuted(true)
        player.command("cycle", arguments: ["mute"])
        let idle = await player.lifecycleDiagnostics()
        #expect(idle.handlesCreated == stopped.handlesCreated + 1)
        #expect(idle.loadCommands == stopped.loadCommands)
        #expect(player.state == .stopped && player.position == .zero && player.isPaused)
        #expect(player.lastError == nil)
        player.play()
        try await eventually("replayed native client with ordered settings") {
            player.state == .playing && player.volume == 37 && !player.isMuted
        }
        let replayed = await player.lifecycleDiagnostics()
        #expect(replayed.handlesCreated == idle.handlesCreated)
        #expect(replayed.loadCommands == idle.loadCommands + 1)
        #expect(player.lastError == nil)
    }

    @Test
    func `rendering commands while stopped stay unloaded and another stop releases the idle client`() async throws {
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: ["ao": "null"], autoPlay: false, logLevel: .info, videoOutput: .metal
        ))
        defer { fixture.close() }
        try await fixture.loadPaused()
        let player = fixture.player
        player.stop()
        try await eventually("stopped before rendering command") { player.state == .stopped }
        let stopped = await player.lifecycleDiagnostics()
        player.command("set", arguments: ["video-rotate", "90"])
        player.command("add", arguments: ["video-zoom", "0.25"])
        player.setProperty("video-zoom", to: "0.5")
        player.command("add", arguments: ["video-zoom", "0.25"])
        let idle = await player.lifecycleDiagnostics()
        #expect(idle.handlesCreated == stopped.handlesCreated + 1)
        #expect(idle.loadCommands == stopped.loadCommands)
        #expect(player.state == .stopped && player.position == .zero && player.isPaused)
        player.stop()
        let released = await player.lifecycleDiagnostics()
        #expect(released.handlesDestroyed == idle.handlesDestroyed + 1)
        #expect(released.handlesCreated == idle.handlesCreated)
        fixture.surface.activateRenderingSurface()
        #expect(await player.lifecycleDiagnostics().handlesCreated == released.handlesCreated)
        player.play()
        try await eventually("replayed rendering configuration") { player.state == .playing }
        var observed: String?
        player.logHandler = { message in
            if let marker = message.message.range(of: "STOPPED_RENDER ") {
                observed = String(message.message[marker.upperBound...])
            }
        }
        player.command("expand-properties", arguments: [
            "print-text", "STOPPED_RENDER rotation=${=video-rotate} zoom=${=video-zoom}",
        ])
        try await eventually("restored rendering settings") { observed != nil }
        #expect(observed?.contains("rotation=90") == true)
        #expect(observed?.contains("zoom=0.750000") == true)
        #expect(player.lastError == nil)
    }
}
