@testable import MPVUI
import Testing

struct MPVEngineParsingTests {
    @Test
    func `duration conversion preserves fractional and negative seconds`() {
        #expect(Duration(mpvSeconds: 1.25) == .milliseconds(1250))
        #expect(Duration(mpvSeconds: -0.5) == .milliseconds(-500))
        #expect(Duration.seconds(2.75).seconds == 2.75)
        #expect(Duration(mpvSeconds: .nan) == nil)
        #expect(Duration(mpvSeconds: .infinity) == nil)
    }

    @Test
    func `hdr target peak preserves extended linear headroom`() {
        #expect(MPVEngine.targetPeakNits(forOutputHeadroom: 4) == 812)
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
    func `metadata parsing copies string values`() {
        let metadata = MPVEngine.parseMetadata(
            .map([
                "title": .string("Example"),
                "track": .integer(3),
            ])
        )

        #expect(metadata == ["title": "Example"])
    }

    @Test
    func `node integer conversion rejects non finite and out of range doubles`() {
        #expect(MPVNodeValue.double(.nan).integerValue == nil)
        #expect(MPVNodeValue.double(.infinity).integerValue == nil)
        #expect(MPVNodeValue.double(9_223_372_036_854_775_808.0).integerValue == nil)
        #expect(MPVNodeValue.double(42.75).integerValue == 42)
    }

    @Test
    func `text subtitle snapshot parsing preserves region order and provenance`() {
        let snapshot = MPVTextSubtitleParser.snapshot(
            from: .array([
                .map(["text": .string("ordinary")]),
                .map([
                    "text": .string("positioned"),
                    "format": .string("webvtt"),
                    "settings": .string("align:start position:10% line:80% size:60%"),
                ]),
            ])
        )

        #expect(snapshot.text == "ordinary\npositioned")
        #expect(snapshot.regions.first?.placement == .automatic)
        #expect(
            snapshot.regions.last?.placement
                == .webVTT(
                    WebVTTPlacement(
                        horizontalPosition: 0.1,
                        verticalPosition: 0.8,
                        horizontalAnchor: .left,
                        verticalAnchor: .top,
                        maximumWidth: 0.6,
                        textAlignment: .left
                    )
                )
        )
    }

    @Test
    func `web VTT default placement remains explicit`() {
        let snapshot = MPVTextSubtitleParser.snapshot(
            from: .array([
                .map([
                    "text": .string("default"),
                    "format": .string("webvtt"),
                    "settings": .string(""),
                ]),
            ])
        )

        #expect(
            snapshot.regions.first?.placement
                == .webVTT(
                    WebVTTPlacement(
                        horizontalPosition: 0.5,
                        verticalPosition: 0.96
                    )
                )
        )
    }

    @Test
    func `vertical web VTT cue swaps placement axes and extent`() {
        let placement = MPVTextSubtitleParser.webVTTPlacement(
            from: "vertical:rl line:20%,center position:30%,line-right size:40% align:end"
        )

        #expect(placement.horizontalPosition == 0.2)
        #expect(placement.verticalPosition == 0.3)
        #expect(placement.horizontalAnchor == .center)
        #expect(placement.verticalAnchor == .bottom)
        #expect(placement.maximumWidth == nil)
        #expect(placement.maximumHeight == 0.3)
        #expect(placement.textAlignment == .right)
        #expect(placement.writingDirection == .verticalGrowingLeft)
    }

    @Test
    func `web VTT logical alignment resolves against cue direction`() {
        let leftToRight = MPVTextSubtitleParser.webVTTPlacement(
            from: "align:start",
            cueText: "Hello"
        )
        #expect(leftToRight.horizontalPosition == 0.5)
        #expect(leftToRight.horizontalAnchor == .left)
        #expect(leftToRight.textAlignment == .left)

        let rightToLeft = MPVTextSubtitleParser.webVTTPlacement(
            from: "align:start",
            cueText: "مرحبا"
        )
        #expect(rightToLeft.horizontalPosition == 0.5)
        #expect(rightToLeft.horizontalAnchor == .right)
        #expect(rightToLeft.textAlignment == .right)
    }

    @Test
    func `web VTT size is clamped to available inline space`() {
        let horizontal = MPVTextSubtitleParser.webVTTPlacement(
            from: "position:90%,center size:60%"
        )
        #expect(abs((horizontal.maximumWidth ?? -1) - 0.2) <= 0.000_001)

        let vertical = MPVTextSubtitleParser.webVTTPlacement(
            from: "vertical:lr position:10%,line-left size:80%"
        )
        #expect(abs((vertical.maximumHeight ?? -1) - 0.8) <= 0.000_001)
    }

    @Test
    func `web VTT invalid settings do not block later valid occurrences`() {
        let placement = MPVTextSubtitleParser.webVTTPlacement(
            from: "position:20%,left position:75%,line-right "
                + "position:25%,line-left align:right align:left"
        )

        #expect(placement.horizontalPosition == 0.25)
        #expect(placement.horizontalAnchor == .left)
        #expect(placement.textAlignment == .left)
    }

    @Test
    func `web VTT fractional snap line retains ordering estimate`() {
        let placement = MPVTextSubtitleParser.webVTTPlacement(from: "line:0.5")

        #expect(abs(placement.verticalPosition - 0.09) <= 0.000_001)
        #expect(placement.verticalAnchor == .top)
    }
}
