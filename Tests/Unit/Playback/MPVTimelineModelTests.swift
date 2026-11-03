@testable import MPVCore
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
        #expect(MPVVideoDimensions(width: 720, height: 480, displayHeight: 0).aspectRatio == 1.5)
    }

    @Test(arguments: [90, -90, 270, 450])
    func `presentation dimensions apply pixel aspect before rotation`(rotation: Int) {
        let information = MPVMediaInformation(
            dimensions: .init(width: 720, height: 576, displayWidth: 1024, displayHeight: 576),
            rotation: rotation
        )

        #expect(information.presentationDimensions?.width == 576)
        #expect(information.presentationDimensions?.height == 1024)
        #expect(information.dimensions?.width == 720)
    }

    @Test
    func `presentation dimensions bound arbitrary rotations and reject missing size`() {
        #expect(MPVMediaInformation().presentationDimensions == nil)
        #expect(MPVMediaInformation(dimensions: .empty).presentationDimensions == nil)

        let information = MPVMediaInformation(dimensions: .init(width: 100, height: 100), rotation: 45)

        #expect(information.presentationDimensions?.width == 142)
        #expect(information.presentationDimensions?.height == 142)
    }
}
