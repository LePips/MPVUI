#if os(macOS) || os(iOS) || os(tvOS)
import AVFoundation
import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.system), .serialized, .enabled(if:
    ProcessInfo.processInfo.environment["MPVUI_RUN_NATIVE_AUDIO_TESTS"] == "1"
))
@MainActor
struct MPVPCMFeedingIntegrationTests {

    @Test
    func `sustained DTS playback across track switch`() async throws {
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        let category = session.category
        let mode = session.mode
        let options = session.categoryOptions
        let multichannel = session.supportsMultichannelContent
        defer {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? session.setCategory(category, mode: mode, options: options)
            try? session.setSupportsMultichannelContent(multichannel)
        }
        try session.setCategory(.playback, mode: .moviePlayback)
        try session.setSupportsMultichannelContent(true)
        try session.setActive(true)
        print("DTS output route", session.currentRoute.outputs.map(\.portType.rawValue), "latency", session.outputLatency)
        #endif

        let fixture = PlaybackFixture(configuration: .init(audio: .init(audioSession: .hostManaged), logLevel: .info, volume: 0))
        defer { fixture.close() }
        let player = fixture.player
        player.setDiagnosticsEnabled(true)
        var audioPTS: Double?
        var messages: [String] = []
        let marker = "DTS_AUDIO_PTS="
        player.logHandler = { message in
            let line = message.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix(marker) {
                audioPTS = Double(line.dropFirst(marker.count))
            } else {
                messages.append("[\(message.prefix)] \(line)")
            }
        }
        var completed = false
        defer {
            if !completed {
                print("DTS playback", player.state, "position", player.position, "audio", player.playbackDiagnostics.audio)
                print(messages.suffix(30).joined(separator: "\n"))
            }
        }

        let url = try TestPaths.testMedia("audio-dts-multitrack.mkv")
        let start = ContinuousClock.now
        player.load(url)
        // HDMI frame-rate matching can pause the first few frames while the display switches modes.
        try await eventually("DTS advances after display matching", timeout: .seconds(12)) {
            player.state == .playing && player.hasVideoFrame && player.position >= .seconds(2)
                && player.playbackDiagnostics.audio.codec == "dts"
                && player.playbackDiagnostics.audio.output == "avfoundation"
                && player.playbackDiagnostics.audio.sourceChannels?.contains("5.1") == true
                && player.playbackDiagnostics.audio.nativePath == "sample-buffer"
        }
        let firstPosition = player.position
        let playing = ContinuousClock.now
        try #require(firstPosition < start.duration(to: playing) + .seconds(1))
        try #require(player.audioTracks.count == 2)
        let alternate = try #require(player.audioTracks.first { !$0.isSelected })

        // Sample both clocks against elapsed time. An advancing video position alone
        // would pass if audio stopped, or if both clocks jumped forward together.
        for second in stride(from: 4, through: 68, by: 2) {
            try await eventually("video reaches \(second) seconds", timeout: .seconds(4)) {
                player.position >= .seconds(second)
            }
            audioPTS = nil
            player.executeCommand("expand-properties", arguments: ["print-text", marker + "${=audio-pts}"])
            try await eventually("active DTS audio timestamp at \(second) seconds", timeout: .seconds(1)) { audioPTS != nil }
            let audio = try #require(audioPTS)
            let expected = firstPosition + playing.duration(to: .now)
            try #require(abs(audio - player.position.seconds) < 0.5, "A/V drift at \(second) s")
            try #require(abs(audio - expected.seconds) < 1.5, "Audio clock at \(second) s, expected \(expected)")

            if second == 34 {
                player.selectTrack(alternate.id)
                try await eventually("the stereo DTS track plays through the native PCM output") {
                    player.audioTracks.first { $0.id == alternate.id }?.isSelected == true
                        && player.playbackDiagnostics.audio.sourceChannels == "stereo"
                        && player.playbackDiagnostics.audio.nativePath == "sample-buffer"
                }
            }
        }
        #expect(player.lastError == nil)
        completed = true
    }

    @Test
    func `paused DTS keeps its audio timestamp`() async throws {
        let audio = try NativeAudioSession(options: ["vid": "auto"])
        defer { audio.close() }
        try await audio.load(TestPaths.testMedia("audio-dts-multitrack.mkv"))
        try await audio.wait("decoded DTS reaches the PCM renderer") {
            audio.string("current-ao") == "avfoundation" && audio.string("audio-codec-name") == "dts"
                && audio.number("audio-pts") > 0.4
        }
        try audio.set("pause", "yes")
        try await audio.wait("player pauses") { audio.string("core-idle") == "yes" }
        let paused = audio.number("audio-pts")
        try #require(paused.isFinite)
        try await Task.sleep(for: .milliseconds(500))
        let held = audio.number("audio-pts")
        #expect(abs(held - paused) < 0.05, "PCM advanced while paused from \(paused) to \(held)")
        let resume = ContinuousClock.now
        try audio.set("pause", "no")
        try await audio.wait("DTS advances after resume", timeout: 2) { audio.number("audio-pts") >= paused + 0.25 }
        #expect(abs(audio.number("audio-pts") - paused - resume.duration(to: .now).seconds) < 0.15)
    }

    @Test(arguments: [false, true])
    func transport(bounded: Bool) async throws {
        let audio = try NativeAudioSession(options: bounded ? ["ao-avfoundation-max-lookahead": "2"] : [:])
        defer { audio.close() }

        #if os(macOS)
        #expect(audio.number("options/ao-avfoundation-max-lookahead") == (bounded ? 2 : 0))
        #else
        #expect(audio.number("options/ao-avfoundation-max-lookahead") == 2)
        #endif

        try await audio.load(TestPaths.baselineMedia)

        try await audio.wait("PCM output and advancing audio clock") {
            audio.string("current-ao") == "avfoundation" && audio.number("audio-pts") > 0.25
        }

        #expect(!audio.string("audio-out-params/format").contains("spdif"))
        try await audio.pauseAndSeek(to: 0.6)
        try audio.set("pause", "no")
        try await audio.wait("PCM EOF") { audio.eof }
    }
}
#endif
