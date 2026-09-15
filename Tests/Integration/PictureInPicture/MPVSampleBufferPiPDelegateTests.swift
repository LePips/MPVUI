#if os(iOS) && !targetEnvironment(macCatalyst)
import AVKit
import CoreMedia
import Foundation
@testable import MPVUI
import Testing

@Suite(.tags(.integration, .pictureInPicture), .serialized)
@MainActor
struct MPVSampleBufferPiPDelegateTests {
    @Test
    func `AVKit delegate transitions publish state and late callbacks cannot revive invalidated PiP`() async throws {
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        try await fixture.loadPaused()
        var modes: [Bool] = []
        let helper = makeHelper(player: fixture.player, layer: fixture.player.sampleBufferDisplayLayer) { modes.append($0) }
        defer { helper.invalidate() }
        let platform = platformController(helper, layer: fixture.player.sampleBufferDisplayLayer)
        helper.pictureInPictureControllerWillStartPictureInPicture(platform)
        #expect(helper.snapshot.isStarting)
        #expect(modes == [true])
        helper.pictureInPictureControllerDidStartPictureInPicture(platform)
        #expect(helper.snapshot.isActive && !helper.snapshot.isStarting)
        helper.pictureInPictureController(platform, didTransitionToRenderSize: CMVideoDimensions(width: 640, height: 360))
        #expect(helper.snapshot.renderSize == CGSize(width: 640, height: 360))
        helper.pictureInPictureControllerWillStopPictureInPicture(platform)
        #expect(helper.snapshot.isStopping)
        helper.pictureInPictureControllerDidStopPictureInPicture(platform)
        #expect(!helper.snapshot.isActive && !helper.snapshot.isStopping)
        #expect(modes == [true, false])
        helper.invalidate()
        let retired = helper.snapshot
        helper.pictureInPictureControllerWillStartPictureInPicture(platform)
        helper.pictureInPictureControllerDidStartPictureInPicture(platform)
        helper.pictureInPictureControllerWillStopPictureInPicture(platform)
        helper.pictureInPictureControllerDidStopPictureInPicture(platform)
        helper.pictureInPictureController(platform, didTransitionToRenderSize: CMVideoDimensions(width: 1, height: 1))
        #expect(helper.snapshot == retired)
    }

    @Test
    func `AVKit playback delegates reflect the native timeline and apply transport requests`() async throws {
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        try await fixture.loadPaused()
        let layer = fixture.player.sampleBufferDisplayLayer
        let helper = makeHelper(player: fixture.player, layer: layer)
        defer { helper.invalidate() }
        let platform = platformController(helper, layer: layer)
        let range = helper.pictureInPictureControllerTimeRangeForPlayback(platform)
        #expect(range.isValid)
        #expect(abs(range.duration.seconds - fixture.player.duration.seconds) < 0.01)
        #expect(helper.pictureInPictureControllerIsPlaybackPaused(platform))
        #expect(!helper.pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(platform))
        helper.pictureInPictureController(platform, setPlaying: true)
        try await eventually("AVKit play advances the native clock") { fixture.player.state == .playing }
        #expect(!helper.pictureInPictureControllerIsPlaybackPaused(platform))
        helper.pictureInPictureController(platform, setPlaying: false)
        try await eventually("AVKit pause freezes the native clock") { fixture.player.state == .paused }
        var completions = 0
        helper.pictureInPictureController(platform, skipByInterval: CMTime(seconds: 0.5, preferredTimescale: 600)) { completions += 1 }
        try await eventually("AVKit skip completes after the native frame is ready") { completions == 1 }
        #expect(helper.snapshot.lastError == nil)
        #expect(fixture.player.position > .seconds(1))
        helper.invalidate()
        #expect(!helper.pictureInPictureControllerTimeRangeForPlayback(platform).isValid)
    }

    @Test
    func `failed start and declined restoration complete through AVKit delegate entry points`() async throws {
        let player = MPVPlayer()
        let layer = AVSampleBufferDisplayLayer()
        let helper = makeHelper(player: player, layer: layer)
        defer { helper.invalidate() }
        let platform = platformController(helper, layer: layer)
        helper.pictureInPictureControllerWillStartPictureInPicture(platform)
        helper.stop()
        #expect(helper.snapshot.isStopping)
        helper.pictureInPictureControllerWillStartPictureInPicture(platform)
        helper.pictureInPictureControllerDidStartPictureInPicture(platform)
        let failure = NSError(domain: "MPVUI.PiPTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Presenter refused"])
        helper.pictureInPictureController(platform, failedToStartPictureInPictureWithError: failure)
        #expect(!helper.snapshot.isStarting && !helper.snapshot.isStopping)
        #expect(helper.snapshot.lastError == .pictureInPictureFailed(operation: .start, message: "Presenter refused"))
        helper.clearLastError()
        #expect(helper.snapshot.lastError == nil)
        var answers: [Bool] = []
        helper.pictureInPictureController(
            platform,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { answers.append($0) }
        )
        try await eventually("declined restoration calls AVKit completion") { answers == [false] }
        helper.invalidate()
        helper.pictureInPictureController(
            platform,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { answers.append($0) }
        )
        #expect(answers == [false, false])
    }

    @Test
    func `startup watchdog retires rendering when AVKit never confirms appearance`() async throws {
        let player = MPVPlayer()
        var modes: [Bool] = []
        let helper = makeHelper(player: player, layer: AVSampleBufferDisplayLayer()) { modes.append($0) }
        defer { helper.invalidate() }
        helper.prepareToStartPictureInPicture()
        try await eventually("missing AVKit start callback times out", timeout: .seconds(12)) { helper.snapshot.lastError != nil }
        #expect(helper.snapshot.lastError == .pictureInPictureTimedOut(operation: .start))
        #expect(!helper.snapshot.isStarting && !helper.snapshot.isStopping)
        #expect(modes == [true, false])
    }

    @Test
    func `playback delegates remain safe after the player is released`() throws {
        var player: MPVPlayer? = MPVPlayer()
        let layer = AVSampleBufferDisplayLayer()
        let helper = try makeHelper(player: #require(player), layer: layer)
        defer { helper.invalidate() }
        let platform = platformController(helper, layer: layer)
        player = nil
        #expect(helper.pictureInPictureControllerIsPlaybackPaused(platform))
        #expect(!helper.pictureInPictureControllerTimeRangeForPlayback(platform).isValid)
        helper.pictureInPictureController(platform, setPlaying: true)
        var completions = 0
        helper.pictureInPictureController(platform, skipByInterval: .invalid) { completions += 1 }
        #expect(completions == 1)
    }

    private func makeHelper(
        player: MPVPlayer, layer: AVSampleBufferDisplayLayer,
        renderingChanged: @escaping @MainActor (Bool) -> Void = { _ in }
    ) -> MPVSampleBufferPictureInPictureController {
        MPVSampleBufferPictureInPictureController(
            player: player, displayLayer: layer, onStateChange: { _ in },
            restoreUserInterface: { false }, onRenderingModeChange: renderingChanged
        )
    }

    /// This object supplies delegate arguments only. These tests establish
    /// callback behavior, not system PiP availability or actual presentation.
    private func platformController(
        _ helper: MPVSampleBufferPictureInPictureController, layer: AVSampleBufferDisplayLayer
    ) -> AVPictureInPictureController {
        AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: layer, playbackDelegate: helper))
    }
}
#endif
