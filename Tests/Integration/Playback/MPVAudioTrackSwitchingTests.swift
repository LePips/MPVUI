import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.integration), .serialized)
@MainActor
struct MPVAudioTrackSwitchingTests {
    @Test(arguments: [1, 2])
    func `audio refresh retains buffered video while replacing the audio stream`(initialTrack: Int) async throws {
        let stream = try SeekGatedMediaStream(TestPaths.multitrackMedia)
        let session = try NativePlaybackSession(options: [
            "audio": "\(initialTrack)", "sid": "1", "sub-auto": "no", "sub-text-intercept": "yes",
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
        try await eventually("audio and video are buffered before switching") {
            session.property("demuxer-cache-duration")?.doubleValue ?? 0 > 8
                && session.property("time-pos")?.doubleValue != nil
                && session.property("demuxer-cache-state")?.mapValue?["idle"]?.boolValue == true
        }
        let bufferedVideo = try #require(videoCacheDuration(session))
        let position = try #require(session.property("time-pos")?.doubleValue)
        let destination = 3 - initialTrack
        stream.arm()
        try session.command(["set", "aid", "\(destination)"])
        try await eventually("audio refresh reaches the delayed source") { stream.isBlocked }
        #expect(videoCacheDuration(session) == bufferedVideo)
        #expect(session.property("aid")?.integerValue == Int64(destination))
        #expect(session.property("pause")?.boolValue == true)
        #expect(session.property("time-pos")?.doubleValue == position)

        stream.resume()
        try session.command(["set", "pause", "no"])
        try await eventually("new audio codec plays in sync with retained video") {
            session.property("audio-codec-name")?.stringValue == (destination == 1 ? "aac" : "opus")
                && session.property("audio-pts")?.doubleValue ?? 0 > position + 1
                && session.property("time-pos")?.doubleValue ?? 0 > position + 1
                && abs(session.property("avsync")?.doubleValue ?? 10) < 0.15
        }
        #expect(MPVTextSubtitleParser.snapshot(from: session.property("sub-text-snapshot")).text.contains("long cue"))

        // Switching back must decode the current position, not stale packets
        // left over from the track's previous selection.
        try session.command(["set", "aid", "\(initialTrack)"])
        try await eventually("returning to the previous track stays synchronized") {
            session.property("audio-codec-name")?.stringValue == (initialTrack == 1 ? "aac" : "opus")
                && session.property("audio-pts")?.doubleValue ?? 0 > position + 1
                && abs(session.property("avsync")?.doubleValue ?? 10) < 0.15
        }
        try session.command(["set", "pause", "yes"])
        try session.command(["seek", "7", "absolute+exact"])
        try await eventually("explicit seek still repositions video and subtitles") {
            abs((session.property("time-pos")?.doubleValue ?? 0) - 7) < 0.15
                && MPVTextSubtitleParser.snapshot(from: session.property("sub-text-snapshot")).text == "long cue"
        }
    }

    @Test(arguments: ["no", "1", "2"])
    func `paused audio selection recovers when the packet cache is full`(initialTrack: String) async throws {
        let session = try NativePlaybackSession(options: [
            "audio": initialTrack, "sid": "no", "sub-auto": "no",
            "cache": "yes", "cache-secs": "20", "demuxer-max-bytes": "65536", "start": "1",
        ])
        defer { session.close() }
        try await session.load(TestPaths.multitrackMedia)
        try await eventually("packet cache reaches its byte limit") {
            session.property("demuxer-cache-state")?.mapValue?["fw-bytes"]?.integerValue ?? 0 >= 65536
        }
        let position = try #require(session.property("time-pos")?.doubleValue)
        let destination = initialTrack == "1" ? "2" : "1"
        try session.command(["set", "aid", destination])
        try await eventually("new audio decoder produces samples with a full cache") {
            session.property("audio-codec-name")?.stringValue == (destination == "1" ? "aac" : "opus")
                && session.property("audio-params")?.mapValue?["samplerate"]?.integerValue == 48000
        }
        #expect(session.property("pause")?.boolValue == true)
        #expect(session.property("time-pos")?.doubleValue == position)
        try session.command(["set", "pause", "no"])
        try await eventually("audio and video resume together") {
            session.property("audio-pts")?.doubleValue ?? 0 > position + 1
                && session.property("time-pos")?.doubleValue ?? 0 > position + 1
                && abs(session.property("avsync")?.doubleValue ?? 10) < 0.15
        }
    }

    @Test(arguments: [MPVPlayerConfiguration.VideoOutput.sampleBuffer, .metal])
    func `repeated audio codec switches preserve playback and the video renderer`(
        output: MPVPlayerConfiguration.VideoOutput
    ) async throws {
        try await assertAudioSwitching(output: output, audioOutput: "null")
    }

    @Test(
        .tags(.system),
        .enabled(if: ProcessInfo.processInfo.environment["MPVUI_RUN_NATIVE_AUDIO_TESTS"] == "1"),
        arguments: [MPVPlayerConfiguration.VideoOutput.sampleBuffer, .metal]
    )
    func `native audio codec switches preserve playback and the video renderer`(
        output: MPVPlayerConfiguration.VideoOutput
    ) async throws {
        try await assertAudioSwitching(output: output, audioOutput: "avfoundation")
    }

    private func assertAudioSwitching(output: MPVPlayerConfiguration.VideoOutput, audioOutput: String) async throws {
        let fixture = PlaybackFixture(configuration: .init(
            additionalOptions: ["ao": audioOutput, "mute": "yes", "sub-auto": "no", "sid": "1"],
            autoPlay: false, videoOutput: output
        ))
        defer { fixture.close() }
        try await fixture.loadPaused(TestPaths.multitrackMedia)
        let player = fixture.player
        let tracks = player.audioTracks
        try #require(tracks.count == 2)
        let before = await player.lifecycleDiagnostics()
        player.play()
        try await eventually("audio and video are playing") { player.state == .playing }
        try await eventually("requested audio output is active") { player.playbackDiagnostics.audio.output == audioOutput }
        let beforeDrops = player.playbackDiagnostics.outputDroppedFrames
        for index in 0 ..< 8 {
            let track = tracks[(index + 1) % tracks.count]
            let position = player.position
            player.selectTrack(track.id)
            try await eventually("destination audio codec is active") {
                player.audioTracks.first { $0.id == track.id }?.isSelected == true
                    && player.mediaInformation.audioCodec == track.codec
            }
            try await eventually("playback advances after switching audio") { player.position > position + .milliseconds(200) }
        }
        try await eventually("audio and video remain synchronized after repeated switches") {
            abs(player.playbackDiagnostics.audioVideoDriftSeconds ?? 10) < 0.15
        }
        let after = await player.lifecycleDiagnostics()
        print(
            "Audio switches: 8; output: \(output)/\(audioOutput); output drops:", beforeDrops as Any,
            "->", player.playbackDiagnostics.outputDroppedFrames as Any,
            "A/V drift:", player.playbackDiagnostics.audioVideoDriftSeconds as Any
        )
        #expect(after.handlesCreated == before.handlesCreated)
        #expect(after.seekingStateTransitions == before.seekingStateTransitions)
        #expect(player.lastError == nil)
    }

    private func videoCacheDuration(_ session: NativePlaybackSession) -> Double? {
        session.property("demuxer-cache-state")?.mapValue?["ts-per-stream"]?.arrayValue?
            .first { $0.mapValue?["type"]?.stringValue == "video" }?
            .mapValue?["cache-duration"]?.doubleValue
    }
}
