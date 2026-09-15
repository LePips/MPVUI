@testable import MPVUI
import Testing

@Suite(.tags(.unit, .subtitles))
struct TextSubtitleSnapshotTests {
    @Test
    func `text subtitle snapshot preserves ordered regions and flattened text`() {
        let placement = WebVTTPlacement(
            horizontalPosition: 0.25,
            verticalPosition: 0.8,
            horizontalAnchor: .left,
            verticalAnchor: .top,
            maximumWidth: 0.6,
            textAlignment: .right,
            writingDirection: .verticalGrowingLeft
        )
        let snapshot = TextSubtitleSnapshot(regions: [
            TextSubtitleRegion(text: "first"),
            TextSubtitleRegion(text: "second", placement: .webVTT(placement)),
        ])

        #expect(snapshot.regions.map(\.text) == ["first", "second"])
        #expect(snapshot.text == "first\nsecond")
        #expect(!snapshot.isEmpty)
        #expect(TextSubtitleSnapshot().isEmpty)
    }
}
