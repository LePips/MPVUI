import CoreMedia
import Foundation
@testable import MPVCore
@testable import MPVUI
import Testing

@Suite(.tags(.integration), .serialized)
@MainActor
struct MPVHeadlessPlaybackTests {

    @Test(arguments: [false, true], [false, true])
    func `controls issued while waiting for video preserve the latest seek and playback intent`(playing: Bool, toggles: Bool) async throws {
        let player = MPVPlayer(configuration: .init(additionalOptions: ["ao": "null"]))
        player.load(TestPaths.multitrackMedia, startTime: .seconds(1))
        try await eventually("video discovery") { !player.videoTracks.isEmpty }
        player.seek(to: .seconds(2))
        player.seek(by: .milliseconds(500))

        if toggles {
            player.togglePlayback()

            if playing {
                player.togglePlayback()
            }
        } else {
            player.pause()

            if playing {
                player.play()
            }
        }

        try await eventually("latest controls delivered while still waiting") {
            player.position == .seconds(2.5) && player.isPaused == !playing
        }

        #expect(player.state == .loading)
        #expect(player.position == .seconds(2.5))
        #expect(player.isPaused == !playing)
        #expect(!player.audioTracks.contains { $0.isSelected })

        let fixture = PlaybackFixture(player: player)
        defer { fixture.close() }

        try await eventually("latest controls applied to synchronized startup") {
            player.state == (playing ? .playing : .paused) && player.hasVideoFrame
                && player.position >= .seconds(2.4) && player.position < .seconds(3.5)
        }

        #expect(player.isPaused == !playing)
        #expect(player.lastError == nil)
        #expect(await player.lifecycleDiagnostics().loadCommands == 1)
        #expect(await player.lifecycleDiagnostics().seekCommands == 0)
    }

    @Test(arguments: ["stop", "replace", "close", "quit"], [false, true])
    func `waiting video loads release native hooks when cancelled`(action: String, waitsForTracks: Bool) async throws {
        let engine = MPVSession(configuration: .init(additionalOptions: ["ao": "null"])) { _ in }
        defer { engine.shutdownSynchronously() }
        engine.load(TestPaths.baselineMedia, playAutomatically: true, startTime: nil, generation: 1)

        if waitsForTracks {
            try await eventually("load waits before either decoder starts") {
                engine.queue.sync { engine.pendingPreloadHookID != nil }
            }

            engine.queue.sync {
                #expect(engine.getString("current-ao") == nil)
                #expect(engine.getInt64("current-tracks/audio/id") == nil)
                #expect(engine.getInt64("current-tracks/video/id") == nil)
                #expect(!engine.hasPlaybackStarted)
            }
        }

        switch action {
        case "stop": engine.stop(generation: 2)
        case "replace":
            try engine.load(TestPaths.testMedia("audio-pcm-stereo.mka"), playAutomatically: true, startTime: nil, generation: 2)
        case "quit": engine.performCommand("quit", arguments: [])
        default: engine.shutdownSynchronously()
        }

        try await eventually("cancelled load leaves no native continuation") {
            engine.queue.sync {
                engine.pendingPreloadHookID == nil && (action == "replace" ? engine.hasPlaybackStarted : engine.handle == nil)
            }
        }

        #expect(engine.queue.sync { engine.fatalPlaybackError == nil })

        if action == "stop" {
            engine.play()

            try await eventually("replay discovers video and waits again") {
                engine.queue.sync { engine.pendingPreloadHookID != nil && engine.lifecycleDiagnostics.loadCommands == 2 }
            }
        }
    }

    @Test(arguments: ["typed", "property", "command"])
    func `explicit video off releases a discovered video for audio playback`(control: String) async throws {
        let player = MPVPlayer(configuration: .init(additionalOptions: ["ao": "null"]))
        defer { player.stop() }
        player.load(TestPaths.baselineMedia)
        try await eventually("video waits for presentation") { !player.videoTracks.isEmpty && player.state == .loading }

        switch control {
        case "typed": player.disableTrack(.video)
        case "property": player.setProperty("options/video", to: "no")
        default: player.executeCommand("no-osd", arguments: ["set", "video", "no"])
        }

        try await eventually("explicit audio playback starts") { player.state == .playing && player.position > .milliseconds(100) }
        #expect(!player.hasVideoFrame)
        #expect(!player.videoTracks.contains { $0.isSelected })
        #expect(player.lastError == nil)
        player.load(TestPaths.multitrackMedia)

        try await eventually("replacement discovers its own tracks") {
            player.mediaInformation.sourceURL == TestPaths.multitrackMedia && !player.videoTracks.isEmpty
        }

        #expect(player.state == .loading)
        #expect(!player.audioTracks.contains { $0.isSelected })
    }

    @Test(arguments: MPVPlayerConfiguration.VideoOutput.allCases, [MPVCacheConfiguration.Mode.disabled, .enabled])
    func `video startup waits for a view and starts both streams without a corrective seek`(
        output: MPVPlayerConfiguration.VideoOutput,
        cache: MPVCacheConfiguration.Mode
    ) async throws {
        let player = MPVPlayer(configuration: .init(additionalOptions: ["ao": "null"], cache: .init(mode: cache), videoOutput: output))
        defer { player.stop() }
        player.setDiagnosticsEnabled(true)
        try player.load(TestPaths.testMedia("video-h264-long-gop.mkv"))
        try await eventually("tracks discovered before the view attaches") { !player.audioTracks.isEmpty && !player.videoTracks.isEmpty }
        #expect(player.state == .loading)
        #expect(player.position == .zero)
        #expect(!player.audioTracks.contains { $0.isSelected })
        #expect(!player.videoTracks.contains { $0.isSelected })
        #expect(!player.hasVideoFrame)
        #expect(player.playbackDiagnostics.startLatencySeconds == nil)

        let position = player.position
        let before = await player.lifecycleDiagnostics()
        let fixture = PlaybackFixture(player: player)
        defer { fixture.close() }

        try await eventually("video and position advance promptly after attachment", timeout: .seconds(2)) {
            player.hasVideoFrame && player.state == .playing && player.position > position + .milliseconds(200)
        }

        if output == .sampleBuffer {
            let clock = try #require(player.sampleBufferDisplayLayer.controlTimebase)
            #expect(CMTimebaseGetRate(clock) > 0)
            #expect(abs(CMTimebaseGetTime(clock).seconds - player.position.seconds) < 0.3)
        }

        try await eventually("audio and video are synchronized", timeout: .seconds(1)) {
            player.playbackDiagnostics.audioVideoDriftSeconds.map { abs($0) < 0.1 } == true
        }

        let attached = await player.lifecycleDiagnostics()
        #expect(attached.handlesCreated == before.handlesCreated)
        #expect(attached.loadCommands == before.loadCommands)
        #expect(attached.seekCommands == 0)
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
            configuration: .init(
                additionalOptions: media == "baseline.mp4" ? ["ao": "null", "vid": "no"] : ["ao": "null"],
                automaticallyPlays: false,
                videoOutput: output
            )
        )
        defer { player.stop() }

        try await eventually("headless audio loaded") {
            player.state == .paused && player.isSeekable && player.audioTracks.contains { $0.isSelected }
        }

        #expect(!player.hasActiveRenderSurface)
        #expect(player.mediaInformation.dimensions == nil)
        #expect(!player.videoTracks.contains { $0.isSelected })
        #expect(player.playbackDiagnostics.decoder.codec == nil)
        #expect(!player.hasVideoFrame)
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
            automaticallyPlays: playing,
            videoOutput: output
        ))
        player.load(TestPaths.multitrackMedia, startTime: .seconds(2))
        player.disableTrack(.video)

        try await eventually("audio ready before attachment") {
            player.state == (playing ? .playing : .paused) && player.isSeekable
        }

        player.setMuted(true)
        player.setVolume(37)
        player.setPlaybackRate(0.5)
        try player.selectTrack(#require(player.videoTracks.first).id)

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
        let player = MPVPlayer(configuration: .init(additionalOptions: ["ao": "null"], automaticallyPlays: false, videoOutput: output))
        player.load(TestPaths.multitrackMedia)
        try await eventually("headless tracks available") { player.state == .loading && !player.videoTracks.isEmpty }

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
        let player = MPVPlayer(configuration: .init(additionalOptions: ["ao": "null"], automaticallyPlays: false))
        player.load(TestPaths.baselineMedia)
        player.disableTrack(.video)
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
            configuration: .init(additionalOptions: ["ao": "null"], automaticallyPlays: false, videoOutput: output)
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
        let engine = MPVSession(configuration: .init(additionalOptions: ["ao": "null"], automaticallyPlays: false)) { _ in }
        defer { engine.shutdownSynchronously() }
        try engine.load(TestPaths.testMedia("video-hevc-8bit.mkv"), playAutomatically: false, startTime: .milliseconds(500), generation: 1)

        try await eventually("video-only source waits after native probing") {
            engine.queue.sync {
                engine.lifecycleDiagnostics.loadCommands == 1 && engine.pendingPreloadHookID != nil
                    && engine.handle != nil && engine.isLoading && engine.fatalPlaybackError == nil
            }
        }

        let player = MPVPlayer(configuration: .init(additionalOptions: ["ao": "null"], automaticallyPlays: false))
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

        #expect(engine.queue.sync { engine.lifecycleDiagnostics.loadCommands == 1 && engine.lifecycleDiagnostics.seekCommands == 0 })
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
        let player = MPVPlayer(configuration: .init(additionalOptions: ["ao": "null", "vid": "no"], automaticallyPlays: false))
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
        player.executeCommand("add", arguments: ["volume", "12"])

        let idle = await player.lifecycleDiagnostics()

        #expect(idle.handlesCreated == stopped.handlesCreated + 1)
        #expect(idle.loadCommands == stopped.loadCommands)
        player.play()
        try await eventually("headless replay preserves command order") { player.state == .playing && player.volume == 37 }

        #expect(player.lastError == nil)
    }
}
