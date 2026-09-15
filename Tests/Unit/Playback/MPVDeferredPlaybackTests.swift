import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.unit), .serialized)
@MainActor
struct MPVDeferredPlaybackTests {
    @Test
    func `convenience initializer queues URL and configured start position`() {
        let player = MPVPlayer(url: TestPaths.baselineMedia, configuration: .init(autoPlay: false, startTime: .seconds(2)))
        #expect(player.state == .loading)
        #expect(player.position == .seconds(2))
        #expect(player.mediaInformation.sourceURL == TestPaths.baselineMedia)
        #expect(player.videoTracks.isEmpty)
    }

    @Test
    func `relative seeks accumulate before a surface exists and clamp at zero`() async throws {
        let player = MPVPlayer()
        player.load(TestPaths.baselineMedia, startTime: .seconds(2))
        player.seek(by: .seconds(3))
        player.seek(by: .seconds(-1))
        try await eventually("queued relative seeks") { player.position == .seconds(4) }
        player.seek(by: .seconds(-10))
        try await eventually("negative queued seek clamped") { player.position == .zero }
        #expect(player.state == .loading)
        #expect(player.lastError == nil)
    }

    @Test
    func `absolute seek replaces the pending position used by the next relative seek`() async throws {
        let player = MPVPlayer()
        player.load(TestPaths.baselineMedia, startTime: .seconds(2))
        player.seek(to: .seconds(7))
        player.seek(by: .seconds(2))
        try await eventually("absolute then relative queued seek") { player.position == .seconds(9) }
        #expect(player.lastError == nil)
    }

    @Test(arguments: [0.0, -1, .nan, .infinity, -.infinity])
    func `invalid playback rates preserve the last accepted rate`(rate: Double) {
        let player = MPVPlayer(configuration: .init(playbackRate: 1.5))
        player.setPlaybackRate(rate)
        #expect(player.playbackRate == 1.5)
        #expect(player.lastError == nil)
    }

    @Test(arguments: [(0.001, 0.01), (1000.0, 100.0)])
    func `valid out of range playback rates clamp to the supported limits`(requested: Double, expected: Double) {
        let player = MPVPlayer()
        player.setPlaybackRate(requested)
        #expect(player.playbackRate == expected)
    }

    @Test
    func `invalid subtitle identity does not change playback state`() {
        let player = MPVPlayer()
        let id = MPVMediaTrackIdentifier(type: .audio, mpvID: 1)
        player.selectSubtitle(id)
        #expect(player.lastError == .invalidSubtitleTrack(id))
        #expect(player.state == .idle)
        #expect(player.selectedSubtitle() == nil)
    }
}
