import CoreMedia
import Foundation
@testable import MPVCore
@testable import MPVUI
import Testing

@Suite(.tags(.integration), .serialized)
@MainActor
struct MPVHeadlessPlaybackTests {

    @Test(arguments: [false, true], [MPVCacheConfiguration.Mode.disabled, .enabled])
    func `attaching video to playing audio starts a synchronized timeline`(
        waitForProgress: Bool,
        cache: MPVCacheConfiguration.Mode
    ) async throws {
        let player = MPVPlayer(configuration: .init(additionalOptions: ["ao": "null"], cache: .init(mode: cache)))
        defer { player.stop() }
        player.setDiagnosticsEnabled(true)
        try player.load(TestPaths.testMedia("video-h264-long-gop.mkv"))
        if waitForProgress {
            try await eventually("audio progresses before the view attaches") {
                player.state == .playing && player.position > .milliseconds(200)
            }
        } else {
            try await eventually("tracks discovered before the view attaches") { !player.audioTracks.isEmpty }
        }
        let position = player.position
        let before = await player.lifecycleDiagnostics()
        let fixture = PlaybackFixture(player: player)
        defer { fixture.close() }
        try await eventually("video and position advance promptly after attachment", timeout: .seconds(2)) {
            guard let clock = player.sampleBufferDisplayLayer.controlTimebase else { return false }
            return player.hasVideoFrame && CMTimebaseGetRate(clock) > 0 && player.position > position + .milliseconds(200)
                && player.position < position + .seconds(3)
                && abs(CMTimebaseGetTime(clock).seconds - player.position.seconds) < 0.3
        }
        try await eventually("audio and video are synchronized", timeout: .seconds(1)) {
            player.playbackDiagnostics.audioVideoDriftSeconds.map { abs($0) < 0.1 } == true
        }
        let attached = await player.lifecycleDiagnostics()
        #expect(attached.handlesCreated == before.handlesCreated)
        #expect(attached.loadCommands == before.loadCommands)
        #expect(!player.isPaused)
        #expect(player.lastError == nil)
    }

    @Test(arguments: MPVPlayerConfiguration.VideoOutput.allCases, ["audio-pcm-stereo.mka", "baseline.mp4"])
    func `loading without a view decodes only audio and supports playback controls`(
        output: MPVPlayerConfiguration.VideoOutput,
        media: String
    ) async throws {
        let player = try MPVPlayer(
            url: TestPaths.testMedia(media),
            configuration: .init(additionalOptions: ["ao": "null"], autoPlay: false, videoOutput: output)
        )
        defer { player.stop() }
        try await eventually("headless audio loaded") {
            player.state == .paused && player.isSeekable && player.audioTracks.contains { $0.isSelected }
        }

        #expect(!player.hasActiveRenderSurface)
        #expect(player.mediaInformation.dimensions == nil)
        #expect(!player.videoTracks.contains { $0.isSelected })
        #expect(player.playbackDiagnostics.decoder.codec == nil)
        #expect(await player.renderOutputSize() == nil)
        player.setVolume(37)
        player.setMuted(true)
        player.setPlaybackRate(1.25)
        player.seek(to: .seconds(1))
        try await eventually("headless paused seek") {
            player.state == .paused && abs(player.position.seconds - 1) < 0.1
        }
        player.play()
        try await eventually("audio clock advances without a video view") {
            player.state == .playing && player.position > .seconds(1.2)
        }
        player.pause()
        try await eventually("headless pause") { player.state == .paused }
        player.stop()
        try await eventually("headless stop") { player.state == .stopped }
        let stopped = await player.lifecycleDiagnostics()

        #expect(stopped.handlesCreated == 1 && stopped.handlesDestroyed == 1)
        player.play()
        try await eventually("headless replay") { player.state == .playing && player.position < .seconds(1) }

        #expect(player.volume == 37 && player.isMuted && player.playbackRate == 1.25)
        #expect(await player.lifecycleDiagnostics().loadCommands == 2)
        #expect(player.lastError == nil)
    }

    @Test(arguments: MPVPlayerConfiguration.VideoOutput.allCases, [false, true])
    func `attaching and removing video preserves the loaded audio session`(
        output: MPVPlayerConfiguration.VideoOutput,
        playing: Bool
    ) async throws {
        let player = MPVPlayer(configuration: .init(
            additionalOptions: ["ao": "null"],
            autoPlay: playing,
            videoOutput: output
        ))
        player.load(TestPaths.multitrackMedia, startTime: .seconds(2))
        try await eventually("audio ready before attachment") {
            player.state == (playing ? .playing : .paused) && player.isSeekable
        }
        player.setMuted(true)
        player.setVolume(37)
        player.setPlaybackRate(0.5)
        let before = await player.lifecycleDiagnostics()
        let fixture = PlaybackFixture(player: player)
        defer { fixture.close() }
        try await eventually("video enabled on the existing media") {
            let size = await player.renderOutputSize()
            return player.mediaInformation.dimensions != nil && player.videoTracks.contains { $0.isSelected } && size != nil
        }

        #expect(player.position >= .seconds(1.9))
        #expect(player.isPaused == !playing)
        let attached = await player.lifecycleDiagnostics()

        #expect(attached.handlesCreated == before.handlesCreated)
        #expect(attached.handlesDestroyed == before.handlesDestroyed)
        #expect(attached.loadCommands == before.loadCommands)

        fixture.surface.detach()
        try await eventually("video decoding disabled after detach") {
            !player.videoTracks.contains { $0.isSelected } && player.mediaInformation.dimensions == nil
        }
        let detached = await player.lifecycleDiagnostics()

        #expect(detached.handlesCreated == before.handlesCreated)
        #expect(detached.handlesDestroyed == before.handlesDestroyed)
        #expect(detached.loadCommands == before.loadCommands)
        #expect(player.isPaused == !playing)
        let position = player.position
        player.play()
        try await eventually("audio continues after detach") { player.position > position + .milliseconds(100) }

        fixture.surface.activateRenderingSurface()
        try await eventually("video restored after reattachment") { player.mediaInformation.dimensions != nil }

        #expect(await player.lifecycleDiagnostics().loadCommands == before.loadCommands)
        #expect(player.volume == 37 && player.isMuted && player.playbackRate == 0.5)
        #expect(player.lastError == nil)
    }

    @Test(arguments: MPVPlayerConfiguration.VideoOutput.allCases)
    func `PiP retention keeps decoding video and releasing it resumes headless playback`(
        output: MPVPlayerConfiguration.VideoOutput
    ) async throws {
        let fixture = PlaybackFixture(configuration: .init(additionalOptions: ["ao": "null"], videoOutput: output))
        defer { fixture.close() }
        try await fixture.loadPaused(TestPaths.multitrackMedia)
        let player = fixture.player
        fixture.surface.retainRenderingForPictureInPicture()
        fixture.surface.detach()

        #expect(player.hasActiveRenderSurface)
        #expect(await player.renderOutputSize() != nil)
        fixture.surface.releaseRenderingFromPictureInPicture()
        fixture.surface.detach()
        try await eventually("video stops after releasing PiP retention") {
            let size = await player.renderOutputSize()
            return !player.videoTracks.contains { $0.isSelected } && size == nil
        }

        #expect(player.lastError == nil)
    }

    @Test(arguments: MPVPlayerConfiguration.VideoOutput.allCases)
    func `explicit video selection survives detachment without decoding offscreen`(
        output: MPVPlayerConfiguration.VideoOutput
    ) async throws {
        let player = MPVPlayer(configuration: .init(additionalOptions: ["ao": "null"], autoPlay: false, videoOutput: output))
        player.load(TestPaths.multitrackMedia)
        try await eventually("headless tracks available") { player.state == .paused && !player.videoTracks.isEmpty }

        let track = try #require(player.videoTracks.first)
        player.selectTrack(track.id)
        _ = await player.lifecycleDiagnostics()

        #expect(await player.renderOutputSize() == nil)
        #expect(!player.videoTracks.contains { $0.isSelected })
        let fixture = PlaybackFixture(player: player)
        defer { fixture.close() }
        try await eventually("requested video selected on attachment") {
            player.videoTracks.contains { $0.id == track.id && $0.isSelected }
        }
        player.disableTrack(.video)
        try await eventually("explicit video off") { !player.videoTracks.contains { $0.isSelected } }
        fixture.surface.detach()
        fixture.surface.activateRenderingSurface()
        _ = await player.lifecycleDiagnostics()

        #expect(!player.videoTracks.contains { $0.isSelected })
        #expect(player.lastError == nil)
    }

    @Test
    func `external video selection waits for an attached view`() async throws {
        let player = MPVPlayer(configuration: .init(additionalOptions: ["ao": "null"], autoPlay: false))
        player.load(TestPaths.baselineMedia)
        try await eventually("headless source loaded") { player.state == .paused && player.isSeekable }
        try player.loadExternalTrack(TestPaths.testMedia("video-hevc-8bit.mkv"), type: .video)
        try await eventually("external video added without a decoder") { player.videoTracks.contains { $0.isExternal } }

        #expect(!player.videoTracks.contains { $0.isSelected })
        #expect(await player.renderOutputSize() == nil)
        let fixture = PlaybackFixture(player: player)
        defer { fixture.close() }
        try await eventually("external video selected when attached") {
            player.videoTracks.contains { $0.isExternal && $0.isSelected } && player.mediaInformation.dimensions != nil
        }

        #expect(player.lastError == nil)
    }

    @Test(arguments: MPVPlayerConfiguration.VideoOutput.allCases, [false, true])
    func `video-only playback starts when a view attaches before or after track discovery`(
        output: MPVPlayerConfiguration.VideoOutput,
        waitsForTracks: Bool
    ) async throws {
        let player = try MPVPlayer(
            url: TestPaths.testMedia("video-hevc-8bit.mkv"),
            configuration: .init(additionalOptions: ["ao": "null"], autoPlay: false, videoOutput: output)
        )
        if waitsForTracks {
            try await eventually("video tracks available without a view") { !player.videoTracks.isEmpty }
        }
        let fixture = PlaybackFixture(player: player)
        defer { fixture.close() }
        try await eventually("video-only load completes across attachment") {
            player.state == .paused && player.mediaInformation.dimensions != nil
        }

        #expect(player.lastError == nil)
    }

    @Test
    func `video without an audio track waits for a surface`() async throws {
        let engine = MPVSession(configuration: .init(additionalOptions: ["ao": "null"], autoPlay: false)) { _ in }
        defer { engine.shutdownSynchronously() }
        try engine.load(TestPaths.testMedia("video-hevc-8bit.mkv"), autoPlay: false, startTime: .milliseconds(500), generation: 1)
        try await eventually("video-only source waits after native probing") {
            engine.queue.sync {
                engine.lifecycleDiagnostics.loadCommands == 1 && engine.needsSourceLoad
                    && engine.handle != nil && engine.isLoading && engine.fatalPlaybackError == nil
            }
        }
        let player = MPVPlayer(configuration: .init(additionalOptions: ["ao": "null"], autoPlay: false))
        let layer = player.sampleBufferDisplayLayer
        let target = MPVRenderTarget(
            layerAddress: Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque())),
            layerOwner: layer,
            drawableWidth: 2,
            drawableHeight: 2,
            usesExtendedDynamicRange: false,
            displaySupportsExtendedDynamicRange: false,
            outputHeadroom: 1
        )
        engine.attach(to: target)
        try await eventually("video-only source loads on attachment") {
            engine.queue.sync { engine.isFileLoaded && engine.getInt64("current-tracks/video/id") != nil }
        }
        engine.detach(fromLayerAddress: target.layerAddress)
        _ = await engine.lifecycleSnapshot()

        #expect(engine.queue.sync { engine.handle == nil && engine.needsSourceLoad && engine.fatalPlaybackError == nil })
        engine.attach(to: target)
        try await eventually("video-only source resumes on reattachment") {
            engine.queue.sync { engine.isFileLoaded && abs(engine.lastPosition.seconds - 0.5) < 0.1 }
        }
    }

    @Test
    func `headless load failure recovers and stopped raw commands remain usable`() async throws {
        let player = MPVPlayer(configuration: .init(additionalOptions: ["ao": "null"], autoPlay: false))
        defer { player.stop() }
        let files = try TemporaryTestDirectory()
        defer { files.remove() }
        player.load(files.url.appendingPathComponent("missing.mp4"))
        try await eventually("missing file failure without a view") { player.state.error != nil }
        player.load(TestPaths.baselineMedia)
        try await eventually("headless load recovery") { player.state == .paused && player.isSeekable }

        #expect(player.lastError == nil)
        player.stop()
        try await eventually("stopped headless player") { player.state == .stopped }
        let stopped = await player.lifecycleDiagnostics()
        player.setVolume(25)
        player.command("add", arguments: ["volume", "12"])
        let idle = await player.lifecycleDiagnostics()

        #expect(idle.handlesCreated == stopped.handlesCreated + 1)
        #expect(idle.loadCommands == stopped.loadCommands)
        player.play()
        try await eventually("headless replay preserves command order") { player.state == .playing && player.volume == 37 }

        #expect(player.lastError == nil)
    }
}
