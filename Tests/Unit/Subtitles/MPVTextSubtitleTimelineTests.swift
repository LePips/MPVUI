@testable import MPVUI
import Testing

@Suite(.tags(.unit, .subtitles))
struct MPVTextSubtitleTimelineTests {
    @Test
    func `snapshots partition overlaps with inclusive starts exclusive ends and gaps`() throws {
        let snapshots = try #require(MPVTextSubtitleTimeline.snapshots(from: .array([
            cue(1, 5, "first"), cue(3, 6, "second"), cue(8, 8.001, "brief"),
        ])))
        #expect(snapshots.map(\.snapshot.text) == ["first", "first\nsecond", "second", "brief"])
        #expect(snapshots.map(\.startTime) == [.seconds(1), .seconds(3), .seconds(5), .seconds(8)])
        #expect(snapshots.map(\.endTime) == [.seconds(3), .seconds(5), .seconds(6), .seconds(8.001)])
        #expect(snapshots.first { $0.contains(.seconds(3)) }?.snapshot.text == "first\nsecond")
        #expect(snapshots.first { $0.contains(.seconds(5)) }?.snapshot.text == "second")
        #expect(snapshots.first { $0.contains(.seconds(6)) } == nil)
        #expect(snapshots.first { $0.contains(.seconds(-1)) } == nil)
    }

    @Test
    func `out of order cues retain decoder region order and WebVTT placement`() throws {
        var webVTT = try #require(cue(2, 5, "top").mapValue)
        webVTT["format"] = .string("webvtt")
        webVTT["settings"] = .string("line:10% position:20%")
        let snapshots = try #require(MPVTextSubtitleTimeline.snapshots(from: .array([
            .map(webVTT), cue(1, 5, "bottom"),
        ])))
        #expect(snapshots.map(\.snapshot.text) == ["bottom", "top\nbottom"])
        guard case .webVTT = snapshots.last?.snapshot.regions.first?.placement else {
            Issue.record("WebVTT placement was lost")
            return
        }
    }

    @Test
    func `identical adjacent presentations merge but gaps remain`() throws {
        let snapshots = try #require(MPVTextSubtitleTimeline.snapshots(from: .array([
            cue(1, 2, "same"), cue(2, 3, "same"), cue(4, 5, "same"),
        ])))
        #expect(snapshots.count == 2)
        #expect(snapshots.first?.startTime == .seconds(1))
        #expect(snapshots.first?.endTime == .seconds(3))
    }

    @Test
    func `empty track is distinct from unavailable or malformed data`() {
        #expect(MPVTextSubtitleTimeline.snapshots(from: .array([])) == [])
        #expect(MPVTextSubtitleTimeline.snapshots(from: nil) == nil)
        for invalid in [
            cue(1, 1, "zero"),
            cue(2, 1, "reversed"),
            cue(.nan, 5, "nan"),
            cue(1, .infinity, "infinite"),
            .map([:])
        ] {
            #expect(MPVTextSubtitleTimeline.snapshots(from: .array([cue(1, 5, "valid"), invalid])) == nil)
        }
    }

    private func cue(_ start: Double, _ end: Double, _ text: String) -> MPVNodeValue {
        .map(["start": .double(start), "end": .double(end), "text": .string(text)])
    }
}
