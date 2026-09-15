@testable import MPVUI
import Testing

@Suite(.tags(.unit))
struct MPVTimelineModelTests {
    @Test(arguments: [(nil, nil), (Duration.seconds(3), Duration.zero), (.seconds(8), .seconds(3))])
    func `chapter duration stays unknown without an end and never becomes negative`(end: Duration?, expected: Duration?) {
        let chapter = MPVChapter(id: 4, startTime: .seconds(5), endTime: end)
        #expect(chapter.duration == expected)
        #expect(chapter.id == 4)
    }

    @Test
    func `display aspect uses pixel aspect correction rather than encoded dimensions`() {
        let dimensions = MPVVideoDimensions(width: 720, height: 576, displayWidth: 1024, displayHeight: 576)
        #expect(dimensions.aspectRatio == 1024.0 / 576.0)
        #expect(!dimensions.isEmpty)
    }

    @Test
    func `invalid display dimensions fall back to sanitized encoded dimensions`() {
        let dimensions = MPVVideoDimensions(width: 720, height: 480, displayWidth: -1, displayHeight: -2)
        #expect(dimensions.aspectRatio == 1.5)
        #expect(dimensions.displayWidth == nil)
        #expect(dimensions.displayHeight == nil)
        let empty = MPVVideoDimensions(width: -1, height: 480)
        #expect(empty.isEmpty)
        #expect(empty.aspectRatio == nil)
        #expect(MPVVideoDimensions(width: 720, height: 480, displayHeight: 0).aspectRatio == nil)
    }
}
