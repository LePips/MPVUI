@testable import MPVUI
import Testing

@Suite(.tags(.integration, .pictureInPicture), .serialized)
@MainActor
struct MPVPiPLifecycleTests {
    @Test
    func `starting without a ready video reports a recoverable error`() {
        let player = MPVPlayer()
        let pip = player.pictureInPicture
        pip.start()
        #expect(pip.lastError == (pip.isSupported ? .pictureInPictureNotReady : .pictureInPictureUnsupported))
        #expect(!pip.isActive)
        #expect(!pip.isTransitioning)
        pip.clearLastError()
        #expect(pip.lastError == nil)
        pip.toggle()
        #expect(pip.lastError != nil)
        #expect(player.state == .idle)
        #expect(player.lastError == nil)
    }

    @Test
    func `retained facade cannot restart after its player is destroyed`() throws {
        var player: MPVPlayer? = MPVPlayer()
        weak var weakPlayer = player
        let pip = try #require(player?.pictureInPicture)
        player = nil
        #expect(weakPlayer == nil)
        #expect(!pip.isSupported)
        #expect(!pip.isPossible)
        #expect(!pip.isActive)
        #expect(!pip.isTransitioning)
        #expect(pip.renderSize == .zero)
        pip.start()
        #expect(pip.lastError == .pictureInPictureUnsupported)
        pip.stop()
        #expect(!pip.isActive)
    }

    #if os(macOS)
    @Test
    func `invalidated presenter ignores delayed system playback callbacks`() {
        let player = MPVPlayer()
        let presenter = MPVMacPictureInPictureController(player: player)
        var stateChanges = 0
        var errors: [MPVPlayerError] = []
        presenter.onStateChange = { stateChanges += 1 }
        presenter.onFailure = { errors.append($0) }
        presenter.start()
        #expect(errors == [presenter.isSupported ? .pictureInPictureNotReady : .pictureInPictureUnsupported])
        presenter.invalidate()
        let before = stateChanges
        presenter.attach(to: MPVPlatformVideoPlayer(player: player))
        presenter.start()
        presenter.prepare()
        presenter.pictureInPictureSetPlaying(true)
        presenter.pictureInPictureSkip(by: 2)
        presenter.invalidate()
        #expect(stateChanges == before)
        #expect(presenter.pictureInPictureShouldClose())
        #expect(!presenter.hasInlineSource)
        #expect(!presenter.presentsVideoOverlay)
        #expect(!presenter.isPossible)
        #expect(presenter.renderSize == .zero)
        #expect(player.state == .idle)
    }
    #endif
}
