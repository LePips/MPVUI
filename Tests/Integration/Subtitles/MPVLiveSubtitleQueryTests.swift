import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.integration, .subtitles), .serialized)
@MainActor
struct MPVLiveSubtitleQueryTests {
    @Test
    func `unselected external subtitle queries include future cues and respect interval boundaries`() async throws {
        let fixture = PlaybackFixture()
        let files = try TemporaryTestDirectory()
        defer { fixture.close()
            files.remove()
        }
        try await fixture.loadPaused()
        let source = try files.write("queried.srt", contents: """
        1
        00:00:00,000 --> 00:00:04,000
        First cue

        2
        00:00:04,000 --> 00:00:08,000
        Second cue

        3
        00:00:08,000 --> 00:00:12,000
        Last cue

        """)
        let previous = Set(fixture.player.subtitleTracks.map(\.id))
        let selected = fixture.player.selectedSubtitle()?.id
        fixture.player.loadExternalSubtitle(source, selecting: nil)
        try await eventually("unselected external subtitle is discovered") {
            fixture.player.subtitleTracks.contains { !previous.contains($0.id) }
        }
        let track = try #require(fixture.player.subtitleTracks.first { !previous.contains($0.id) })
        let cues = try await fixture.player.textSubtitleSnapshots(for: track.id)
        #expect(cues.map(\.snapshot.text) == ["First cue", "Second cue", "Last cue"])
        #expect(try await fixture.player.textSubtitleSnapshot(for: track.id, at: .seconds(4)).text == "Second cue")
        #expect(try await fixture.player.textSubtitleSnapshot(for: track.id, at: .seconds(12)).isEmpty)
        #expect(fixture.player.selectedSubtitle()?.id == selected)
        #expect(fixture.player.state == .paused)
        #expect(fixture.player.lastError == nil)
    }

    @Test
    func `subtitle roles keep independent delays and visibility and moving a track clears its old role`() async throws {
        let fixture = PlaybackFixture()
        let files = try TemporaryTestDirectory()
        defer { fixture.close()
            files.remove()
        }
        var latest = TextSubtitleSnapshot()
        let stream = fixture.player.textSubtitleStream()
        let observation = Task { @MainActor in
            for await snapshot in stream {
                latest = snapshot
            }
        }
        defer { observation.cancel() }
        try await fixture.loadPaused()
        let primary = try files.write("primary.srt", contents: "1\n00:00:00,000 --> 00:00:10,000\nPrimary\n")
        let secondary = try files.write("secondary.srt", contents: "1\n00:00:00,000 --> 00:00:10,000\nSecondary\n")
        fixture.player.loadExternalSubtitle(primary, selecting: .primary)
        fixture.player.loadExternalSubtitle(secondary, selecting: .secondary)
        try await eventually("both subtitle roles display independently") {
            Set(latest.regions.map(\.text)) == ["Primary", "Secondary"]
        }
        #expect(Set(latest.regions.compactMap(\.role)) == [.primary, .secondary])
        fixture.player.setSubtitlesVisible(false, for: .secondary)
        try await eventually("secondary visibility leaves primary alone") { latest.text == "Primary" }
        fixture.player.setSubtitleDelay(.seconds(5), for: .primary)
        try await eventually("delayed primary cue leaves the current interval") { latest.isEmpty }
        fixture.player.setSubtitleDelay(.zero, for: .primary)
        fixture.player.setSubtitlesVisible(true, for: .secondary)
        try await eventually("restoring independent subtitle settings restores both cues") { latest.regions.count == 2 }
        let secondaryID = try #require(fixture.player.selectedSubtitle(for: .secondary)?.id)
        fixture.player.selectSubtitle(secondaryID, for: .primary)
        try await eventually("moving a subtitle clears its former role") {
            fixture.player.selectedSubtitle(for: .primary)?.id == secondaryID
                && fixture.player.selectedSubtitle(for: .secondary) == nil && latest.text == "Secondary"
        }
        #expect(fixture.player.lastError == nil)
    }

    @Test
    func `enabling interception on an existing native session preserves paused playback`() async throws {
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        try await fixture.loadPaused()
        var subtitles = fixture.player.textSubtitleStream().makeAsyncIterator()
        #expect(await subtitles.next() == TextSubtitleSnapshot())
        try await eventually("live native interception becomes enabled") {
            await fixture.player.textSubtitleInterceptionForTesting() == true
        }
        #expect(fixture.player.state == .paused)
        #expect(fixture.player.lastError == nil)
    }
}
