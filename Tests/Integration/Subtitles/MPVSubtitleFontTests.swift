import AVFoundation
import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.integration, .subtitles), .serialized)
struct MPVSubtitleFontTests {
    enum FontUseCase: CaseIterable {
        case plainText
        case missingASSFont
        case authoredASSFont
    }

    @MainActor @Test(arguments: MPVPlayerConfiguration.VideoOutput.allCases, FontUseCase.allCases)
    func `client subtitle fonts select the expected family`(
        videoOutput: MPVPlayerConfiguration.VideoOutput,
        useCase: FontUseCase
    ) async throws {
        let directory = try TemporaryTestDirectory()
        defer { directory.remove() }
        let fonts = try SubtitleFontFixture(in: directory.url)
        let authoredFamily = useCase == .authoredASSFont ? fonts.authored.family : "MissingTestSubtitleFont"
        let subtitle = try directory.write(
            useCase == .plainText ? "client.srt" : "client.ass",
            contents: useCase == .plainText ? """
            1
            00:00:00,000 --> 00:00:11,500
            Client subtitle font

            """ : """
            [Script Info]
            ScriptType: v4.00+
            PlayResX: 640
            PlayResY: 360

            [V4+ Styles]
            Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
            Style: Default,\(authoredFamily),32,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,1

            [Events]
            Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            Dialogue: 0,0:00:00.00,0:00:11.50,Default,,0,0,0,,Client subtitle font

            """
        )
        let fixture = PlaybackFixture(configuration: .init(
            autoPlay: false, hardwareDecoding: .disabled, videoOutput: videoOutput,
            logLevel: .verbose, additionalOptions: [
                "ao": "null", "osd-level": "0", "sub-auto": "no",
                "sub-fonts-dir": fonts.directory.path,
                "sub-font": fonts.fallback.family,
                // Only the files supplied by this client may satisfy font selection.
                "sub-font-provider": "none",
            ]
        ))
        defer { fixture.close() }
        let player = fixture.player
        var logs: [String] = []
        player.logHandler = { message in
            if message.prefix == "sub/ass" {
                logs.append(message.message)
            }
        }
        // ASS must retain native rendering even when the app requests semantic text.
        var sawSemanticText = false
        var observation: Task<Void, Never>?
        if useCase != .plainText {
            let stream = player.textSubtitleStream()
            observation = Task { @MainActor in
                for await snapshot in stream where !snapshot.isEmpty {
                    sawSemanticText = true
                }
            }
        }
        defer { observation?.cancel() }
        try await fixture.loadPaused(at: .seconds(7))
        player.loadExternalTrack(subtitle, type: .subtitle, select: true)
        let expected = useCase == .authoredASSFont ? fonts.authored : fonts.fallback
        try await eventually("client font \(expected.postScriptName) selected; logs: \(logs)") {
            player.subtitleTracks.contains { $0.isExternal && $0.isSelected }
                && logs.contains { $0.contains("fontselect:") && $0.contains(expected.postScriptName) }
        }

        // Reinitializing a subtitle decoder after seeks and track switches must
        // retain the client font configuration, including paths containing spaces.
        for destination in [1.0, 10.5, 11.7, 0.1, 7.0] {
            try #require(await player.seekForPictureInPicture(to: .seconds(destination)))
        }
        let track = try #require(player.subtitleTracks.first { $0.isExternal })
        player.disableTrack(.subtitle)
        try await eventually("subtitles disabled") { !player.subtitleTracks.contains(where: \.isSelected) }
        let beforeReselect = logs.count
        player.selectTrack(track.id)
        try await eventually("client font selected after re-enabling subtitles") {
            player.subtitleTracks.contains { $0.id == track.id && $0.isSelected }
                && logs.dropFirst(beforeReselect).contains {
                    $0.contains("fontselect:") && $0.contains(expected.postScriptName)
                }
        }
        player.play()
        try await eventually("playback through the cue") { player.position.seconds > 8 }
        player.pause()
        try await eventually("paused playback") { player.isPaused }
        #expect(!sawSemanticText)
        #expect(player.lastError == nil)
        #expect(player.videoOutput == videoOutput)
        if videoOutput == .sampleBuffer {
            #expect(player.sampleBufferDisplayLayer.sampleBufferRenderer.status != .failed)
        }
        let failures = logs.filter { $0.contains("Error opening font") || $0.contains("failed to find any fallback") }
        #expect(failures.isEmpty, "Unexpected font failures: \(failures)")
    }
}
