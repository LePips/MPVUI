import Libmpv
@testable import MPVUI
import Testing

@Suite(.tags(.unit, .subtitles))
struct MPVTextSubtitleParsingTests {
    @Test
    func `malformed snapshot regions are ignored and omitted WebVTT settings use defaults`() {
        #expect(MPVTextSubtitleParser.snapshot(from: nil).isEmpty)
        #expect(MPVTextSubtitleParser.snapshot(from: .string("not a list")).isEmpty)
        let snapshot = MPVTextSubtitleParser.snapshot(from: .array([
            .none, .map([:]), .map(["text": .integer(1)]), .map(["text": .string("")]),
            .map(["text": .string("Visible cue"), "format": .string("webvtt")]),
        ]))
        #expect(snapshot.regions.count == 1)
        #expect(snapshot.text == "Visible cue")
        #expect(snapshot.regions.first?.placement == .webVTT(WebVTTPlacement(horizontalPosition: 0.5, verticalPosition: 0.96)))
    }

    @Test(arguments: [
        ("vertical:rl line:2", Float(0.86), WebVTTPlacement.HorizontalAnchor.right),
        ("vertical:lr line:2", 0.14, .left),
        ("vertical:rl line:-2", 0.09, .left),
        ("vertical:lr line:-2", 0.91, .right),
        ("vertical:rl line:25%,start", 0.25, .right),
        ("vertical:lr line:25%,start", 0.25, .left),
        ("vertical:rl line:25%,end", 0.25, .left),
        ("vertical:lr line:25%,end", 0.25, .right),
        ("vertical:lr position:50%,center", 0.04, .left),
    ])
    func `vertical line edges reflect writing direction and signed snap positions`(
        settings: String, position: Float, anchor: WebVTTPlacement.HorizontalAnchor
    ) {
        let result = MPVTextSubtitleParser.webVTTPlacement(from: settings)
        #expect(abs(result.horizontalPosition - position) < 0.000_01)
        #expect(result.horizontalAnchor == anchor)
    }

    @Test(arguments: [
        ("line:25%,center", Float(0.25), WebVTTPlacement.VerticalAnchor.center),
        ("line:25%,end", 0.25, .bottom),
        ("line:-2", 0.91, .bottom),
    ])
    func `horizontal line anchors preserve authored percentages and negative lines`(
        settings: String, position: Float, anchor: WebVTTPlacement.VerticalAnchor
    ) {
        let result = MPVTextSubtitleParser.webVTTPlacement(from: settings)
        #expect(abs(result.verticalPosition - position) < 0.000_01)
        #expect(result.verticalAnchor == anchor)
    }

    @Test(arguments: [
        ("\u{200F}Hello", WebVTTPlacement.TextAlignment.left, WebVTTPlacement.HorizontalAnchor.left),
        ("\u{200E}مرحبا", .right, .right),
        ("123 — שלום", .left, .left),
        ("123 — Hello", .right, .right),
    ])
    func `end alignment follows directional marks or the first strong letter`(
        text: String, alignment: WebVTTPlacement.TextAlignment, anchor: WebVTTPlacement.HorizontalAnchor
    ) {
        let result = MPVTextSubtitleParser.webVTTPlacement(from: "align:end", cueText: text)
        #expect(result.textAlignment == alignment)
        #expect(result.horizontalAnchor == anchor)
    }

    @Test(arguments: [
        "nocolon align: align:bogus unknown:value", "vertical:up line:nan position:nan% size:inf%",
        "line:25%,bad position:101% size:-1%", "line:25%, position:bad size:101%",
    ])
    func `invalid cue settings leave the default placement intact`(settings: String) {
        #expect(MPVTextSubtitleParser.webVTTPlacement(from: settings) == MPVTextSubtitleParser.webVTTPlacement(from: ""))
    }

    @Test
    func `track selection identifies subtitle roles without assigning roles to audio`() {
        let tracks = MPVEngine.parseTracks(.array([
            .map(["id": .integer(1), "type": .string("sub"), "selected": .bool(true), "main-selection": .integer(0)]),
            .map(["id": .integer(2), "type": .string("sub"), "selected": .bool(true), "main-selection": .integer(1)]),
            .map(["id": .integer(3), "type": .string("sub"), "selected": .bool(false), "main-selection": .integer(1)]),
            .map(["id": .integer(1), "type": .string("audio"), "selected": .bool(true), "main-selection": .integer(0)]),
        ]))
        #expect(tracks.map(\.subtitleRole) == [.primary, .secondary, nil, nil])
        #expect(tracks.map(\.isSelected) == [true, true, false, true])
    }

    @Test
    func `subtitle snapshot identity changes even when text does not`() {
        func snapshot(_ id: Int64, _ role: String) -> TextSubtitleSnapshot {
            MPVTextSubtitleParser.snapshot(from: .array([.map([
                "text": .string("same"), "track-id": .integer(id), "role": .string(role),
            ])]))
        }
        #expect(snapshot(1, "primary") != snapshot(1, "secondary"))
        #expect(snapshot(1, "primary") != snapshot(2, "primary"))
        #expect(snapshot(1, "unknown").regions.first?.role == nil)
        #expect(snapshot(-1, "primary").regions.first?.trackID == nil)
    }

    @Test
    func `text subtitle snapshot parsing preserves region order and placement`() {
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
