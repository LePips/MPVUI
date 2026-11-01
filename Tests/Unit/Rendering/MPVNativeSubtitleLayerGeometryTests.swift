import AVFoundation
import CoreGraphics
@testable import MPVUI
import QuartzCore
import Testing

@Suite(.tags(.unit))
@MainActor
struct MPVNativeSubtitleLayerGeometryTests {

    @Test
    func `video and subtitle layers share layout and explicit resize animations`() {
        let host = MPVMetalLayer()
        let video = AVSampleBufferDisplayLayer()
        let subtitles = AVSampleBufferDisplayLayer()
        host.addSublayer(video)
        host.addSublayer(subtitles)
        host.videoSublayer = video
        host.osdSublayer = subtitles
        host.bounds = CGRect(x: 4, y: 6, width: 640, height: 360)
        #expect(video.bounds == host.bounds)
        #expect(subtitles.bounds == video.bounds)
        #expect(subtitles.position == video.position)
        #expect(subtitles.anchorPoint == video.anchorPoint)

        let animation = CABasicAnimation(keyPath: "bounds.size")
        animation.fromValue = CGSize(width: 320, height: 180)
        animation.toValue = CGSize(width: 640, height: 360)
        animation.duration = 0.4
        host.add(animation, forKey: "resize")
        #expect(video.animation(forKey: "resize")?.duration == 0.4)
        #expect(subtitles.animation(forKey: "resize")?.duration == 0.4)
        host.removeAnimation(forKey: "resize")
        #expect(video.animation(forKey: "resize") == nil)
        #expect(subtitles.animation(forKey: "resize") == nil)

        // A superseded host must not alter a layer now attached elsewhere.
        let successor = MPVMetalLayer()
        successor.addSublayer(subtitles)
        successor.osdSublayer = subtitles
        successor.bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        host.bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(subtitles.bounds == successor.bounds)
    }
}
