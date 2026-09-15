import Foundation
@testable import MPVUI
import SwiftUI
import Testing

@Suite(.tags(.integration, .pictureInPicture), .serialized)
@MainActor
struct MPVPiPTimelineTests {
    @Test(arguments: [MPVPlayerConfiguration.VideoOutput.sampleBuffer, .metal])
    func `native overlay submission reports backend acceptance and clearing preserves playback`(backend: MPVPlayerConfiguration
        .VideoOutput) async throws
    {
        let fixture = PlaybackFixture(configuration: .init(
            autoPlay: false, videoOutput: backend, additionalOptions: ["ao": "null"]
        ))
        defer { fixture.close() }
        try await fixture.loadPaused()
        let renderer = ImageRenderer(content: Color.red.frame(width: 4, height: 4))
        let bitmap = try #require(renderer.cgImage.flatMap(MPVVideoOverlayBitmap.init))
        let accepted = await fixture.player.setPictureInPictureOverlay(bitmap)
        #expect(accepted == (backend == .sampleBuffer))
        #expect(await fixture.player.setPictureInPictureOverlay(nil))
        fixture.player.clearPictureInPictureOverlay()
        _ = await fixture.player.lifecycleDiagnostics()
        #expect(fixture.player.state == .paused)
        #expect(fixture.player.lastError == nil)
    }

    @Test
    func `PiP can seek to EOF and reopen the same source for a backward skip`() async throws {
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        try await fixture.loadPaused()
        let duration = fixture.player.duration
        #expect(duration > .zero)
        #expect(await fixture.player.seekForPictureInPicture(to: duration))
        try await eventually("endpoint seek reaches the terminal timeline") { fixture.player.state == .ended }
        #expect(await fixture.player.seekForPictureInPicture(to: duration + .seconds(10)))
        let before = await fixture.player.lifecycleDiagnostics()
        #expect(await fixture.player.seekForPictureInPicture(to: .seconds(2)))
        try await eventually("backward PiP skip reopens paused media") {
            fixture.player.isPaused && abs(fixture.player.position.seconds - 2) < 0.2
        }
        #expect(await fixture.player.lifecycleDiagnostics().loadCommands == before.loadCommands + 1)
        #expect(fixture.player.lastError == nil)
    }
}
