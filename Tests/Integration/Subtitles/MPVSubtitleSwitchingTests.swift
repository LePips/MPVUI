import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.integration, .subtitles), .serialized)
@MainActor
struct MPVSubtitleSwitchingTests {
    @Test(arguments: MPVSubtitleRole.allCases)
    func `subtitle preroll keeps buffered audio and video playable`(role: MPVSubtitleRole) async throws {
        let stream = try SeekGatedMediaStream(TestPaths.multitrackMedia)
        let session = try NativePlaybackSession(options: [
            "audio": "auto", "sid": "no", "sub-auto": "no", "sub-text-intercept": "yes",
            "cache": "yes", "cache-secs": "10", "cache-pause": "yes", "start": "1",
        ])
        defer {
            stream.resume()
            withExtendedLifetime(stream) { session.close() }
        }
        try session.registerStream(
            protocol: "gated", userData: Unmanaged.passUnretained(stream).toOpaque(), open: SeekGatedMediaStream.open
        )
        try session.command(["loadfile", "gated://multitrack.mkv"])
        try await eventually("audio and video are buffered") {
            session.property("demuxer-cache-duration")?.doubleValue ?? 0 > 8
                && session.property("time-pos")?.doubleValue != nil
                && session.property("demuxer-cache-state")?.mapValue?["idle"]?.boolValue == true
        }
        let beforeBytes = try #require(session.property("demuxer-cache-state")?.mapValue?["fw-bytes"]?.integerValue)
        stream.arm()
        try session.command(["set", role.selectionProperty, "1"])
        try await eventually("subtitle refresh seek reaches the delayed source") { stream.isBlocked }
        let buffered = try #require(session.property("demuxer-cache-state")?.mapValue)
        #expect(buffered["fw-bytes"]?.integerValue == beforeBytes)
        #expect(buffered["cache-duration"]?.doubleValue ?? 0 > 8)

        // No source bytes can arrive. Only the A/V packets buffered before the
        // subtitle switch can advance playback through this interval.
        let position = try #require(session.property("time-pos")?.doubleValue)
        try session.command(["set", "pause", "no"])
        try await eventually("video plays from retained packets during subtitle preroll", timeout: .seconds(3)) {
            session.property("time-pos")?.doubleValue ?? 0 > position + 1
        }
        #expect(stream.isBlocked)
        stream.resume()
        try await eventually("subtitle catch-up returns the current cue") {
            MPVTextSubtitleParser.snapshot(from: session.property("sub-text-snapshot")).regions.contains {
                $0.text == "long cue" && $0.role == role
            }
        }
        // A real seek must still reposition both A/V and subtitles.
        try session.command(["set", "pause", "yes"])
        try session.command(["seek", "7", "absolute+exact"])
        try await eventually("explicit seek updates the subtitle and playback time") {
            abs((session.property("time-pos")?.doubleValue ?? 0) - 7) < 0.15
                && MPVTextSubtitleParser.snapshot(from: session.property("sub-text-snapshot")).text == "long cue"
        }
        try session.command(["set", role.selectionProperty, "2"])
        try await eventually("paused track switching displays the destination track") {
            MPVTextSubtitleParser.snapshot(from: session.property("sub-text-snapshot")).text.contains("EN track cue 2")
        }
        try session.command(["set", role.selectionProperty, "no"])
        #expect(MPVTextSubtitleParser.snapshot(from: session.property("sub-text-snapshot")).isEmpty)
    }

    @Test(arguments: MPVSubtitleRole.allCases)
    func `paused subtitle switches recover cues when the packet cache is full`(role: MPVSubtitleRole) async throws {
        let session = try NativePlaybackSession(options: [
            "audio": "auto", "sid": "no", "sub-auto": "no", "sub-text-intercept": "yes",
            "cache": "yes", "cache-secs": "20", "demuxer-max-bytes": "65536", "start": "1",
        ])
        defer { session.close() }
        try await session.load(TestPaths.multitrackMedia)
        try await eventually("packet cache reaches its byte limit") {
            session.property("demuxer-cache-state")?.mapValue?["fw-bytes"]?.integerValue ?? 0 >= 65536
        }
        try session.command(["set", role.selectionProperty, "1"])
        try await eventually("paused subtitle decode progresses despite the full A/V cache") {
            MPVTextSubtitleParser.snapshot(from: session.property("sub-text-snapshot")).text.contains("first cue")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MPVUI_SUBTITLE_SWITCH_FIXTURE"] != nil))
    func `switching embedded text subtitles preserves playback`() async throws {
        let environment = ProcessInfo.processInfo.environment
        let reference = try URL(fileURLWithPath: #require(environment["MPVUI_SUBTITLE_SWITCH_FIXTURE"]))
        var options = ["sub-auto": "no", "sid": "no", "mute": "yes"]
        if let log = environment["MPVUI_SUBTITLE_SWITCH_LOG"] {
            options["log-file"] = log
        }
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: options, autoPlay: false, logLevel: .verbose
        ))
        defer { fixture.close() }
        let player = fixture.player
        var latest = TextSubtitleSnapshot()
        let stream = player.textSubtitleStream()
        let observation = Task { @MainActor in
            for await snapshot in stream {
                latest = snapshot
            }
        }
        defer { observation.cancel() }
        var logs: [String] = []
        player.logHandler = { logs.append("\($0.prefix): \($0.message)") }
        try await fixture.loadPaused(reference, at: .seconds(300))
        let tracks = player.subtitleTracks.filter { $0.codec == "subrip" }
        try #require(tracks.count >= 2)
        player.play()
        try await eventually("playback started") { player.state == .playing }
        try await Task.sleep(for: .seconds(1))
        logs.removeAll()
        let before = await player.lifecycleDiagnostics()
        let beforeDiagnostics = player.playbackDiagnostics
        for index in 0 ..< 12 {
            let track = tracks[index % min(tracks.count, 3)]
            let position = player.position
            player.selectSubtitle(track.id)
            try await eventually("subtitle track selected") { player.selectedSubtitle()?.id == track.id }
            try await Task.sleep(for: .milliseconds(400))
            #expect(player.position > position)
            #expect(latest.regions.allSatisfy { $0.trackID == track.id })
        }
        let after = await player.lifecycleDiagnostics()
        print(
            "Subtitle switches: 12; output drops:", beforeDiagnostics.outputDroppedFrames as Any,
            "->", player.playbackDiagnostics.outputDroppedFrames as Any
        )
        #expect(!logs.contains { $0.contains("Video frame delayed due to waiting on subtitles") })
        #expect(after.handlesCreated == before.handlesCreated)
        #expect(after.seekingStateTransitions == before.seekingStateTransitions)
        #expect(after.bufferingStateTransitions == before.bufferingStateTransitions)
        #expect(player.lastError == nil)
    }
}
