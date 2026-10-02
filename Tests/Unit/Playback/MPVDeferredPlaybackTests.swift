import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.unit), .serialized)
@MainActor
struct MPVDeferredPlaybackTests {
    @Test
    func `convenience initializer starts loading with configured start position`() {
        let player = MPVPlayer(url: TestPaths.baselineMedia, configuration: .init(
            additionalOptions: ["ao": "null"], autoPlay: false, startTime: .seconds(2)
        ))
        #expect(player.state == .loading)
        #expect(player.position == .seconds(2))
        #expect(player.mediaInformation.sourceURL == TestPaths.baselineMedia)
        #expect(player.videoTracks.isEmpty)
    }

    @Test
    func `relative seeks accumulate before client creation and clamp at zero`() async {
        let engine = MPVEngine(configuration: .init()) { _ in }
        engine.queue.sync { engine.pendingStartTime = .seconds(2) }
        engine.seek(by: .seconds(3))
        engine.seek(by: .seconds(-1))
        _ = await engine.lifecycleSnapshot()
        #expect(engine.queue.sync { engine.pendingStartTime == .seconds(4) })
        engine.seek(by: .seconds(-10))
        _ = await engine.lifecycleSnapshot()
        #expect(engine.queue.sync { engine.pendingStartTime == .zero })
    }

    @Test
    func `absolute seek replaces the pending position used by the next relative seek`() async {
        let engine = MPVEngine(configuration: .init()) { _ in }
        engine.queue.sync { engine.pendingStartTime = .seconds(2) }
        engine.seek(to: .seconds(7))
        engine.seek(by: .seconds(2))
        _ = await engine.lifecycleSnapshot()
        #expect(engine.queue.sync { engine.pendingStartTime == .seconds(9) })
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
