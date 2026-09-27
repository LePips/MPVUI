import AVFoundation
import CoreMedia
import Foundation
import Libmpv
@testable import MPVUI
import Testing

@Suite(.tags(.integration), .serialized)
@MainActor
struct MPVPlaybackControlTests {
    @Test
    func `chapter controls navigate authored boundaries in both directions`() async throws {
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        try await fixture.loadPaused(TestPaths.multitrackMedia)
        #expect(fixture.player.mediaInformation.chapters.map(\.title) == ["Opening", "Middle", "Ending"])
        fixture.player.nextChapter()
        try await eventually("next chapter begins at four seconds") { abs(fixture.player.position.seconds - 4) < 0.2 }
        fixture.player.nextChapter()
        try await eventually("next chapter begins at eight seconds") { abs(fixture.player.position.seconds - 8) < 0.2 }
        fixture.player.previousChapter()
        try await eventually("previous chapter returns to four seconds") { abs(fixture.player.position.seconds - 4) < 0.2 }
        #expect(fixture.player.isPaused)
        #expect(fixture.player.lastError == nil)
    }

    @Test
    func `audio delay survives renderer recreation as a native runtime property`() async throws {
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: ["ao": "null"],
            autoPlay: false,
            logLevel: .info,
            videoOutput: .sampleBuffer
        ))
        defer { fixture.close() }
        try await fixture.loadPaused()
        let player = fixture.player
        player.setAudioDelay(.milliseconds(250))
        // Ask mpv to return the actual property through its normal log channel.
        var delay: Double?
        player.logHandler = { message in
            if let marker = message.message.range(of: "AUDIO_DELAY=") {
                delay = Double(message.message[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        player.command("expand-properties", arguments: ["print-text", "AUDIO_DELAY=${=audio-delay}"])
        try await eventually("native audio delay is acknowledged") { delay == 0.25 }
        fixture.surface.detach()
        fixture.surface.activateRenderingSurface()
        try await eventually("media resumes after surface recreation") { player.state == .paused && player.isSeekable }
        delay = nil
        player.command("expand-properties", arguments: ["print-text", "AUDIO_DELAY=${=audio-delay}"])
        try await eventually("audio delay survives recreation") { delay == 0.25 }
        #expect(player.lastError == nil)
    }

    @Test
    func `toggle resumes and pauses the same native clock`() async throws {
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        try await fixture.loadPaused()
        let player = fixture.player
        let clock = try #require(player.sampleBufferDisplayLayer.controlTimebase)

        player.togglePlayback()
        try await eventually("toggle resumes clock") { player.state == .playing && CMTimebaseGetRate(clock) > 0 }
        player.togglePlayback()
        try await eventually("toggle pauses clock") { player.isPaused && CMTimebaseGetRate(clock) == 0 }
        #expect(player.lastError == nil)
        #expect(await player.lifecycleDiagnostics().loadCommands == 1)
    }

    @Test
    func `relative seeks move both directions and preserve paused playback`() async throws {
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        try await fixture.loadPaused()
        let player = fixture.player
        player.seek(by: .milliseconds(400))
        try await eventually("forward relative seek") { player.isPaused && abs(player.position.seconds - 1.4) < 0.1 }
        player.seek(by: .milliseconds(-800))
        try await eventually("backward relative seek") { player.isPaused && abs(player.position.seconds - 0.6) < 0.1 }
        #expect(player.lastError == nil)
        #expect(await player.lifecycleDiagnostics().loadCommands == 1)
    }

    @Test
    func `frame stepping advances and reverses decoded frames without starting playback`() async throws {
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        try await fixture.loadPaused()
        let player = fixture.player
        let position = player.position
        player.stepForward()
        try await eventually("next decoded frame") { player.isPaused && player.position > position }
        let advanced = player.position
        player.stepBackward()
        try await eventually("previous decoded frame") { player.isPaused && player.position < advanced }
        #expect(abs(player.position.seconds - position.seconds) < 0.1)
        #expect(player.lastError == nil)
    }

    @Test
    func `playback rate reaches the native clock and survives pause resume`() async throws {
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        try await fixture.loadPaused()
        let player = fixture.player
        let clock = try #require(player.sampleBufferDisplayLayer.controlTimebase)
        player.setPlaybackRate(1.5)
        player.play()
        try await eventually("native clock at requested rate") { player.state == .playing && abs(CMTimebaseGetRate(clock) - 1.5) < 0.01 }
        player.pause()
        try await eventually("rate change remains paused") { player.isPaused && CMTimebaseGetRate(clock) == 0 }
        #expect(player.playbackRate == 1.5)
        player.play()
        try await eventually("resumed clock retains rate") { player.state == .playing && abs(CMTimebaseGetRate(clock) - 1.5) < 0.01 }
        #expect(player.lastError == nil)
    }

    @Test
    func `mute commands toggle the native value in their submitted order`() async throws {
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        try await fixture.loadPaused()
        let player = fixture.player
        player.setMuted(true)
        // Cycling the native value must unmute only if setMuted reached mpv.
        // The optimistic Swift property alone cannot satisfy this assertion.
        player.command("cycle", arguments: ["mute"])
        try await eventually("native unmute observation") { !player.isMuted }
        player.toggleMute()
        player.command("cycle", arguments: ["mute"])
        try await eventually("native mute cycle observation") { !player.isMuted }
        #expect(player.lastError == nil)
    }

    @Test(arguments: [MPVPlayerConfiguration.VideoOutput.sampleBuffer, .metal])
    func `stopped media retires its renderer and can be replayed from its beginning`(
        output: MPVPlayerConfiguration.VideoOutput
    ) async throws {
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: ["ao": "null"], autoPlay: false, videoOutput: output
        ))
        defer { fixture.close() }
        try await fixture.loadPaused()
        let player = fixture.player
        let before = await player.lifecycleDiagnostics()
        player.stop()
        try await eventually("stop acknowledged") { player.state == .stopped }
        let stopped = await player.lifecycleDiagnostics()
        #expect(stopped.handlesDestroyed == before.handlesDestroyed + 1)
        #expect(stopped.handlesCreated == before.handlesCreated)
        #expect(player.isPaused && player.position == .zero)
        // Visible-view updates and a detached/re-attached surface must stay
        // cheap until an explicit playback request arrives.
        fixture.surface.activateRenderingSurface()
        fixture.surface.detach()
        fixture.surface.activateRenderingSurface()
        #expect(await player.lifecycleDiagnostics().handlesCreated == stopped.handlesCreated)
        player.togglePlayback()
        try await eventually("stopped media reloaded") { player.state == .playing && player.position.seconds < 0.8 }
        #expect(player.mediaInformation.sourceURL == TestPaths.baselineMedia)
        #expect(player.lastError == nil)
        #expect(await player.lifecycleDiagnostics().loadCommands == 2)
        #expect(await player.lifecycleDiagnostics().handlesCreated == before.handlesCreated + 1)
    }

    @Test
    func `stop replay restores external selections and native runtime properties`() async throws {
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: ["ao": "null"], autoPlay: false, logLevel: .info, videoOutput: .sampleBuffer
        ))
        defer { fixture.close() }
        let files = try TemporaryTestDirectory()
        defer { files.remove() }
        let subtitle = try files.write("replay.srt", contents: "1\n00:00:00,000 --> 00:00:12,000\nReplay subtitle\n")
        try await fixture.loadPaused(TestPaths.multitrackMedia, at: .seconds(5))
        let player = fixture.player
        player.loadExternalTrack(subtitle, type: .subtitle, select: true)
        try await eventually("external subtitle selected") { player.subtitleTracks.contains { $0.isExternal && $0.isSelected } }
        player.setVolume(37)
        player.setMuted(true)
        player.setPlaybackRate(1.25)
        player.setAudioDelay(.milliseconds(250))
        player.setSubtitleDelay(.milliseconds(125))
        player.stop()
        try await eventually("runtime-configured item stopped") { player.state == .stopped }
        player.play()
        try await eventually("external subtitle restored on replay") {
            player.state == .playing && player.position.seconds < 2
                && player.subtitleTracks.contains { $0.isExternal && $0.isSelected }
        }
        var observed: [String: String] = [:]
        player.logHandler = { message in
            guard let marker = message.message.range(of: "REPLAY_RUNTIME ") else { return }
            for field in message.message[marker.upperBound...].split(whereSeparator: \.isWhitespace) {
                let parts = field.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    observed[String(parts[0])] = String(parts[1])
                }
            }
        }
        player.command("expand-properties", arguments: [
            "print-text", "REPLAY_RUNTIME volume=${=volume} mute=${mute} speed=${=speed} audio=${=audio-delay} sub=${=sub-delay}",
        ])
        try await eventually("native replay properties observed") { observed.count == 5 }
        #expect(observed["volume"].flatMap(Double.init) == 37)
        #expect(observed["mute"] == "yes")
        #expect(observed["speed"].flatMap(Double.init) == 1.25)
        #expect(observed["audio"].flatMap(Double.init) == 0.25)
        #expect(observed["sub"].flatMap(Double.init) == 0.125)
        #expect(player.lastError == nil)
    }

    @Test
    func `failed load can recover using the next valid media item`() async throws {
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        let files = try TemporaryTestDirectory()
        defer { files.remove() }
        let player = fixture.player
        player.load(files.url.appendingPathComponent("missing.mp4"))
        try await eventually("missing file failure") { player.state.error != nil }
        guard case let .playbackFailed(code, message) = player.state.error else {
            Issue.record("Expected mpv's end-file loading error, got \(String(describing: player.state.error))")
            return
        }
        #expect(code == MPV_ERROR_LOADING_FAILED.rawValue)
        #expect(!message.isEmpty)
        try await fixture.loadPaused()
        #expect(player.lastError == nil)
        #expect(player.state.error == nil)
        #expect(player.mediaInformation.sourceURL == TestPaths.baselineMedia)
    }
}
