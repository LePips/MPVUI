import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.unit), .serialized)
@MainActor
struct MPVAutomaticVideoOutputTests {
    @Test(arguments: [MPVVideoFeature.nativeSubtitles, .bakedOverlays, .zoomAndPan])
    func `advanced features switch automatic native output before metadata without starting playback`(feature: MPVVideoFeature) {
        let player = MPVPlayer(configuration: .init(autoPlay: false))
        #expect(player.videoOutput == .sampleBuffer)
        let result = player.requestVideoFeatures([feature])
        #expect(player.videoOutput == .metal)
        #expect(player.state == .idle)
        #expect(player.isPaused)
        #expect(result.outcome == .switchedToMetal)
        #expect(result.requestedFeatures == [feature])
        #expect(result.unavailableFeatures.isEmpty)
        #expect(result.requiresReload)
        #if os(iOS) && !targetEnvironment(macCatalyst)
        #expect(result.losesPictureInPicture)
        #else
        #expect(!result.losesPictureInPicture)
        #endif
    }

    @Test
    func `early zoom property keeps Metal on subsequent loads`() {
        let player = MPVPlayer(configuration: .init(autoPlay: false))
        player.setProperty("video-zoom", to: "0.25")
        #expect(player.state == .idle)
        #expect(player.videoOutput == .metal)
        #expect(player.videoFeatureRequestResult?.outcome == .switchedToMetal)
        player.load(TestPaths.baselineMedia, autoPlay: false)
        #expect(player.videoOutput == .metal)
        #expect(player.videoOutputFallbackReason?.contains("video-zoom") == true)
        player.load(TestPaths.baselineMedia, autoPlay: false)
        #expect(player.videoOutput == .metal)
        #expect(player.videoOutputFallbackReason?.contains("video-zoom") == true)
        #expect(player.isPaused)
    }

    @Test(arguments: [false, true])
    func `rendering fallback retains a stopped source and deferred seek for later play`(useCommand: Bool) async throws {
        let player = MPVPlayer(configuration: .init(autoPlay: false))
        player.load(TestPaths.baselineMedia, autoPlay: false)
        player.stop()
        try await eventually("stopped source") { player.state == .stopped }
        player.pause()
        player.seek(to: .seconds(3))
        try await eventually("deferred stopped seek") { player.position == .seconds(3) }
        if useCommand {
            player.command("add", arguments: ["video-zoom", "0.25"])
        } else {
            player.setProperty("video-rotate", to: "90")
        }
        #expect(player.state == .stopped)
        #expect(player.videoOutput == .metal)
        player.play()
        try await eventually("retained source restart") { player.state == .loading }
        #expect(player.position == .seconds(3))
        #expect(player.videoOutput == .metal)
    }

    @Test
    func `explicit native output keeps its existing feature policy and next-load behavior`() {
        let player = MPVPlayer(configuration: .init(autoPlay: false, videoOutput: .sampleBuffer))
        player.setProperty("video-zoom", to: "0.25")
        #expect(player.videoOutput == .sampleBuffer)
        #expect(player.videoFeatureRequestResult?.outcome == .awaitingVideoMetadata)
        player.command("vf", arguments: ["add", "hflip"])
        #expect(player.videoOutput == .sampleBuffer)
        player.updateDolbyVisionStatus(.init(sourceProfile: 8))
        #expect(player.videoOutput == .sampleBuffer)
        #expect(player.videoFeatureRequestResult?.outcome == .requiresMetalFallback)
        player.requestVideoFeatures([.zoomAndPan], policy: .preferFeatures)
        #expect(player.videoOutput == .metal)
        player.load(TestPaths.baselineMedia, autoPlay: false)
        #expect(player.videoOutput == .sampleBuffer)
    }

    @Test
    func `explicit preservation policy still governs automatic feature requests`() {
        let player = MPVPlayer(configuration: .init(autoPlay: false, nativeVideoFeaturePolicy: .preserveDolbyVision))
        player.updateDolbyVisionStatus(.init(sourceProfile: 8))
        let result = player.requestVideoFeatures([.zoomAndPan])
        #expect(player.videoOutput == .sampleBuffer)
        #expect(result.outcome == .requiresMetalFallback)
    }

    @Test
    func `selected authored SDR subtitles switch the default output while intercepted text stays native`() {
        let player = MPVPlayer(configuration: .init(autoPlay: false))
        let subtitle = MPVMediaTrack(id: 1, type: .subtitle, codec: "ass", isSelected: true)
        player.apply(.init(generation: nil, update: .media(.init(tracks: [subtitle]))))
        player.updateDolbyVisionStatus(.unknown)
        #expect(player.videoOutput == .metal)
        #expect(player.videoFeatureRequestResult?.requestedFeatures == [.nativeSubtitles])
        #expect(player.videoFeatureRequestResult?.outcome == .switchedToMetal)

        let textPlayer = MPVPlayer(configuration: .init(autoPlay: false))
        _ = textPlayer.textSubtitleStream()
        let text = MPVMediaTrack(id: 2, type: .subtitle, codec: "subrip", isSelected: true)
        textPlayer.apply(.init(generation: nil, update: .media(.init(tracks: [text]))))
        textPlayer.updateDolbyVisionStatus(.unknown)
        #expect(textPlayer.videoOutput == .sampleBuffer)
        #expect(textPlayer.videoFeatureRequestResult == nil)
    }

    @Test
    func `per-item feature fallback without persisted raw settings retries native on the next load`() {
        let player = MPVPlayer(configuration: .init(autoPlay: false))
        player.requestVideoFeatures([.bakedOverlays])
        #expect(player.videoOutput == .metal)
        player.load(TestPaths.baselineMedia, autoPlay: false)
        #expect(player.videoOutput == .sampleBuffer)
        #expect(player.videoFeatureRequestResult == nil)
    }

    @Test
    func `typed playback audio and chapter controls do not select another renderer`() {
        let player = MPVPlayer(configuration: .init(autoPlay: false))
        player.play()
        player.pause()
        player.togglePlayback()
        player.setVolume(65)
        player.setMuted(true)
        player.toggleMute()
        player.setPlaybackRate(1.25)
        player.seek(to: .seconds(1))
        player.seek(by: .seconds(2))
        player.setAudioDelay(.milliseconds(20))
        player.setSubtitleDelay(.milliseconds(20))
        player.setSubtitlesVisible(false)
        player.nextChapter()
        player.previousChapter()
        #expect(player.videoOutput == .sampleBuffer)
        #expect(player.videoFeatureRequestResult == nil)
        #expect(player.videoOutputFallbackReason == nil)
    }

    @Test
    func `raw playback audio and track controls keep automatic native output`() {
        let player = MPVPlayer(configuration: .init(autoPlay: false))
        for property in ["audio-delay", "sid", "secondary-sid", "sub-delay", "cache-pause-wait", "demuxer-max-bytes"] {
            player.setProperty(property, to: "1")
        }
        player.command("add", arguments: ["chapter", "1"])
        player.command("cycle", arguments: ["aid"])
        player.command("set", arguments: ["audio-delay", "0.1"])
        player.command("seek", arguments: ["1", "relative"])
        player.command("sub-add", arguments: ["/tmp/subtitle.srt", "auto"])
        #expect(player.videoOutput == .sampleBuffer)
        #expect(player.videoOutputFallbackReason == nil)
    }

    @Test(arguments: ["video-rotate", "brightness", "options/video-pan-x", "unclassified-rendering-property"])
    func `raw advanced properties retain the full renderer across loads`(property: String) {
        let player = MPVPlayer(configuration: .init(autoPlay: false))
        player.setProperty(property, to: "1")
        #expect(player.videoOutput == .metal)
        player.load(TestPaths.baselineMedia, autoPlay: false)
        #expect(player.videoOutput == .metal)
    }

    @Test(arguments: ["vf", "overlay-add", "unclassified-command"])
    func `raw advanced commands retain the full renderer across loads`(command: String) {
        let player = MPVPlayer(configuration: .init(autoPlay: false))
        player.command(command)
        #expect(player.videoOutput == .metal)
        #expect(player.state == .idle)
        player.load(TestPaths.baselineMedia, autoPlay: false)
        #expect(player.videoOutput == .metal)
    }

    @Test
    func `raw property command checks the transformed property`() {
        let player = MPVPlayer(configuration: .init(autoPlay: false))
        player.command("add", arguments: ["video-zoom", "0.25"])
        #expect(player.videoOutput == .metal)
        player.load(TestPaths.baselineMedia, autoPlay: false)
        #expect(player.videoOutput == .metal)
    }

    @Test(arguments: [
        ("video-zoom", "0"), ("video-pan-x", "-0.0"), ("video-pan-y", "0.0"),
        ("video-scale-x", "1"), ("video-scale-y", "1.0"), ("options/video-zoom", "0"),
    ])
    func `neutral geometry does not create a renderer fallback`(property: String, value: String) {
        let player = MPVPlayer(configuration: .init(autoPlay: false))
        player.setProperty(property, to: value)
        #expect(player.videoOutput == .sampleBuffer)
        #expect(player.videoOutputFallbackReason == nil)
        #expect(player.videoFeatureRequestResult == nil)
        player.load(TestPaths.baselineMedia, autoPlay: false)
        #expect(player.videoOutput == .sampleBuffer)
    }

    @Test
    func `neutral geometry does not clear an existing persistent rendering fallback`() {
        let player = MPVPlayer(configuration: .init(autoPlay: false))
        player.setProperty("video-zoom", to: "0.25")
        player.setProperty("video-zoom", to: "0")
        #expect(player.videoOutput == .metal)
        player.load(TestPaths.baselineMedia, autoPlay: false)
        #expect(player.videoOutput == .metal)
        #expect(player.videoOutputFallbackReason != nil)
    }

    @Test
    func `rejected managed properties do not trigger fallback`() {
        let player = MPVPlayer(configuration: .init(autoPlay: false))
        player.setProperty("vo", to: "gpu-next")
        player.setProperty("scale", to: "lanczos")
        #expect(player.videoOutput == .sampleBuffer)
        #expect(player.videoOutputFallbackReason == nil)
    }
}
