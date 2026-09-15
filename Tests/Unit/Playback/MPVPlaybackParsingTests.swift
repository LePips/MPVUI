import Libmpv
@testable import MPVUI
import Testing

@Suite(.tags(.unit))
struct MPVPlaybackParsingTests {
    @Test
    func `display suspension composes with user playback intent`() {
        #expect(MPVEngine.pauseValue(playing: true, displaySwitching: true) == "yes")
        #expect(MPVEngine.pauseValue(playing: false, displaySwitching: true) == "yes")
        #expect(MPVEngine.pauseValue(playing: false, displaySwitching: false) == "yes")
        #expect(MPVEngine.pauseValue(playing: true, displaySwitching: false) == "no")
    }

    @Test
    func `duration conversion preserves fractional and negative seconds`() {
        #expect(Duration(mpvSeconds: 1.25) == .milliseconds(1250))
        #expect(Duration(mpvSeconds: -0.5) == .milliseconds(-500))
        #expect(Duration.seconds(2.75).seconds == 2.75)
        #expect(Duration(mpvSeconds: .nan) == nil)
        #expect(Duration(mpvSeconds: .infinity) == nil)
    }

    @Test
    func `seekable range parsing discards invalid ranges`() {
        let ranges = MPVEngine.parseSeekableRanges(
            .array([
                .map(["start": .double(1.5), "end": .double(4)]),
                .map(["start": .double(8), "end": .double(3)]),
                .map(["start": .double(5)]),
                .map(["start": .double(.nan), "end": .double(9)]),
                .map(["start": .double(6), "end": .double(6)]),
            ])
        )

        #expect(ranges == [
            .seconds(1.5) ... .seconds(4),
            .seconds(6) ... .seconds(6),
        ])
    }

    @Test
    func `track parsing keeps cross type identities distinct`() {
        let tracks = MPVEngine.parseTracks(
            .array([
                .map([
                    "id": .integer(1),
                    "type": .string("video"),
                    "codec": .string("hevc"),
                    "selected": .bool(true),
                ]),
                .map([
                    "id": .integer(1),
                    "type": .string("audio"),
                    "lang": .string("eng"),
                    "selected": .bool(true),
                ]),
            ])
        )

        #expect(tracks.count == 2)
        #expect(tracks[0].mpvID == 1)
        #expect(tracks[1].mpvID == 1)
        #expect(tracks[0].id != tracks[1].id)
        #expect(tracks[0].codec == "hevc")
        #expect(tracks[1].language == "eng")
        #expect(tracks[0].isSelected)
        #expect(tracks[1].isSelected)
    }

    @Test
    func `chapter parsing uses next chapter as end time`() {
        let chapters = MPVEngine.parseChapters(
            .array([
                .map(["title": .string("Opening"), "time": .double(0)]),
                .map(["title": .string("Feature"), "time": .double(30)]),
            ])
        )

        #expect(chapters.count == 2)
        #expect(chapters[0].endTime == .seconds(30))
        #expect(chapters[1].endTime == nil)
    }

    @Test
    func `chapter boundaries skip malformed times without changing identities or order`() {
        let chapters = MPVEngine.parseChapters(.array([
            .map(["title": .string("Opening"), "time": .double(0)]),
            .none,
            .map(["title": .string("Unknown time")]),
            .map(["time": .double(.nan)]),
            .map(["title": .string("Feature"), "time": .double(30)]),
            .map(["time": .double(.infinity)]),
        ]))

        #expect(chapters.map(\.id) == [0, 2, 3, 4, 5])
        #expect(chapters.map(\.startTime) == [.zero, .zero, .zero, .seconds(30), .zero])
        #expect(chapters.map(\.endTime) == [.seconds(30), .seconds(30), .seconds(30), nil, nil])
        #expect(chapters[0].title == "Opening")
        #expect(chapters[3].title == "Feature")
    }

    @Test
    func `large chapter tables retain every boundary`() {
        let count = 10000
        let chapters = MPVEngine.parseChapters(.array((0 ..< count).map {
            .map(["time": .double(Double($0))])
        }))

        #expect(chapters.count == count)
        for (index, chapter) in chapters.enumerated() {
            #expect(chapter.id == index)
            #expect(chapter.startTime == .seconds(index))
            #expect(chapter.endTime == (index + 1 < count ? .seconds(index + 1) : nil))
        }
    }

    @Test
    func `metadata parsing copies string values`() {
        let metadata = MPVEngine.parseMetadata(
            .map([
                "title": .string("Example"),
                "track": .integer(3),
            ])
        )

        #expect(metadata == ["title": "Example"])
    }
}
