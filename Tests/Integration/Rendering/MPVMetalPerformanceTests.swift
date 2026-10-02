import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.integration), .serialized)
@MainActor
struct MPVMetalPerformanceTests {
    @Test(arguments: ["baseline.mp4", "video-h264-120fps.mkv", "color-hdr10.mkv"])
    func `Metal playback renders seeks and recreates with bounded decoder threading`(media: String) async throws {
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: ["ao": "null", "sid": "no"],
            autoPlay: false,
            logLevel: .info,
            videoOutput: .metal
        ))
        defer { fixture.close() }
        let player = fixture.player
        var messages: [String] = []
        player.logHandler = { messages.append($0.message) }
        let url = try TestPaths.testMedia(media)
        try await fixture.loadPaused(url, at: .seconds(0.25))
        try await eventually("bounded Metal presentation") {
            player.playbackDiagnostics.renderingQuality.effectiveOptions["swapchain-depth"] == "2"
                && player.playbackDiagnostics.freshRenderPasses?.isEmpty == false
        }
        #if !targetEnvironment(simulator)
        if media == "baseline.mp4" {
            #expect(player.mediaInformation.hardwareDecoder == "videotoolbox")
            #expect(!messages.contains { $0.contains("VK_KHR_video_decode_queue") })
        }
        #endif
        let before = await player.lifecycleDiagnostics()
        #expect(await player.seekForPictureInPicture(to: .seconds(0.5)))
        try await eventually("paused Metal seek") {
            player.isPaused && abs(player.position.seconds - 0.5) < 0.15
        }
        player.play()
        try await eventually("Metal playback advances") { player.position.seconds > 0.8 }
        player.pause()
        try await eventually("Metal playback pauses") { player.isPaused }
        let after = await player.lifecycleDiagnostics()
        #expect(after.handlesCreated == before.handlesCreated)
        #expect(player.lastError == nil)

        player.stop()
        try await eventually("Metal resources retired") {
            let state = await player.lifecycleDiagnostics()
            return state.handlesCreated == state.handlesDestroyed
        }
        try await fixture.loadPaused(url, at: .seconds(0.25))
        #expect(player.lastError == nil)
        #expect(await (player.lifecycleDiagnostics()).handlesCreated == before.handlesCreated + 1)
    }

    @Test
    func `automatic Metal decoding retains software fallback`() async throws {
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: ["ao": "null", "keep-open": "yes"],
            videoOutput: .metal
        ))
        defer { fixture.close() }
        try fixture.player.load(TestPaths.testMedia("image-webp-animated.webp"), autoPlay: true)
        try await eventually("software decoded animation rendered by Metal") {
            fixture.player.position.seconds >= 0.75
                && fixture.player.playbackDiagnostics.decoder.session == .software
                && fixture.player.playbackDiagnostics.freshRenderPasses?.isEmpty == false
        }
        #expect(fixture.player.lastError == nil)
    }

    @Test(arguments: [false, true])
    func `presentation depth override survives recreation`(override: Bool) async throws {
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: ["ao": "null"].merging(override ? ["swapchain-depth": "3"] : [:]) { _, new in new },
            autoPlay: false,
            renderingQuality: .init(preset: .highQuality),
            videoOutput: .metal
        ))
        defer { fixture.close() }
        for _ in 0 ..< 2 {
            try await fixture.loadPaused()
            try await eventually("requested presentation depth") {
                fixture.player.playbackDiagnostics.renderingQuality.effectiveOptions["swapchain-depth"] == (override ? "3" : "2")
            }
            fixture.player.stop()
            try await eventually("configured renderer stopped") {
                let state = await fixture.player.lifecycleDiagnostics()
                return state.handlesCreated == state.handlesDestroyed
            }
        }
    }
}
