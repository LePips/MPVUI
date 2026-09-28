import AVFoundation
import CoreGraphics
@testable import MPVUI
import QuartzCore
import Testing
#if canImport(UIKit)
import UIKit
#endif

@Suite(.tags(.integration), .serialized)
@MainActor
struct MPVSampleBufferResizeTests {
    #if canImport(UIKit)
    @Test
    func `UIKit layout animation keeps native video in step while playing`() async throws {
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        try await fixture.loadPaused()
        fixture.player.play()
        try await eventually("native playback starts") { fixture.player.state == .playing }
        let before = await fixture.player.lifecycleDiagnostics()
        let position = fixture.player.position
        let host = fixture.surface.metalLayer
        let video = fixture.player.sampleBufferDisplayLayer
        let end = CGRect(x: 0, y: 0, width: 220, height: 310)
        UIView.animate(withDuration: 0.8, delay: 0, options: .curveEaseInOut) {
            fixture.surface.bounds = end
            fixture.surface.layoutIfNeeded()
        }
        var intermediateWidths: Set<Int> = []
        for _ in 0 ..< 12 {
            try await Task.sleep(for: .milliseconds(40))
            let hostSize = try #require(host.presentation()).bounds.size
            let videoSize = try #require(video.presentation()).bounds.size
            #expect(abs(hostSize.width - videoSize.width) < 1)
            #expect(abs(hostSize.height - videoSize.height) < 1)
            intermediateWidths.insert(Int(hostSize.width))
        }
        #expect(intermediateWidths.count > 5)
        try await Task.sleep(for: .milliseconds(400))
        #expect(video.frame == host.bounds)
        #expect(fixture.player.position > position)
        #expect(video.isReadyForDisplay)
        #expect(video.sampleBufferRenderer.status != .failed)
        let after = await fixture.player.lifecycleDiagnostics()
        #expect(after.handlesCreated == before.handlesCreated)
        #expect(after.loadCommands == before.loadCommands)
    }
    #endif

    @Test
    func `native video geometry follows the backing layer before view layout`() throws {
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        let host = fixture.surface.metalLayer
        let video = fixture.player.sampleBufferDisplayLayer
        try #require(video.superlayer === host)
        for size in [CGSize(width: 480, height: 270), CGSize(width: 200, height: 310)] {
            host.bounds.size = size
            #expect(video.frame == host.bounds)
        }
    }

    @Test(arguments: [false, true])
    func `native video shares the host resize animation`(spring: Bool) async throws {
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        let host = fixture.surface.metalLayer
        let video = fixture.player.sampleBufferDisplayLayer
        try await Task.sleep(for: .milliseconds(50))
        let start = host.bounds
        let end = CGRect(x: 0, y: 0, width: 600, height: 240)
        let animation = spring ? CASpringAnimation(keyPath: "bounds") : CABasicAnimation(keyPath: "bounds")
        animation.fromValue = start
        animation.toValue = end
        animation.duration = 0.6
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.bounds = end
        host.add(animation, forKey: "resize")
        CATransaction.commit()
        try #require(video.animation(forKey: "resize") != nil)
        for _ in 0 ..< 10 {
            try await Task.sleep(for: .milliseconds(25))
            let hostSize = try #require(host.presentation()).bounds.size
            let videoSize = try #require(video.presentation()).bounds.size
            #expect(abs(hostSize.width - videoSize.width) < 1)
            #expect(abs(hostSize.height - videoSize.height) < 1)
        }
        host.removeAnimation(forKey: "resize")
        #expect(video.animation(forKey: "resize") == nil)
        #expect(video.frame == host.bounds)
    }
}
