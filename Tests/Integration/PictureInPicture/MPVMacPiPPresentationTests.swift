#if os(macOS) && !targetEnvironment(macCatalyst)
import _MPVUIPictureInPicture
import AppKit
@testable import MPVUI
import Testing

@Suite(.tags(.integration, .pictureInPicture), .serialized)
@MainActor
struct MPVMacPiPPresentationTests {
    @Test
    func `unavailable system presenter reports unsupported without moving the surface`() async throws {
        let fixture = PlaybackFixture()
        defer { fixture.close() }
        try await fixture.loadPaused()
        let controller = MPVMacPictureInPictureController(player: fixture.player, systemController: nil)
        var failure: MPVPlayerError?
        controller.onFailure = { failure = $0 }
        controller.attach(to: fixture.surface)
        controller.start()
        #expect(!controller.isSupported)
        #expect(!controller.isPossible)
        #expect(failure == .pictureInPictureUnsupported)
        #expect(fixture.surface.window === fixture.window)
    }

    @Test
    func `appearance completes presentation and close restores the same rendering session`() async throws {
        let fixture = PlaybackFixture()
        let presenter = ControlledPiPPresenter()
        presenter.appearsImmediately = false
        let controller = MPVMacPictureInPictureController(player: fixture.player, systemController: presenter)
        defer {
            controller.invalidate()
            fixture.close()
        }
        try await fixture.loadPaused()
        let initial = await fixture.player.lifecycleDiagnostics()
        let layer = fixture.surface.metalLayer
        controller.attach(to: fixture.surface)
        #expect(controller.hasInlineSource)
        #expect(controller.isPossible)
        controller.start()
        #expect(!controller.isActive)
        #expect(controller.isTransitioning)
        #expect(!controller.isPossible)
        #expect(presenter.replacementWindow === fixture.window)
        #expect(fixture.surface.superview === presenter.content?.view)
        controller.start()
        #expect(presenter.presentCount == 1)
        let content = try #require(presenter.content)
        content.viewDidAppear()
        content.viewDidLayout()
        #expect(controller.isActive)
        #expect(!controller.isTransitioning)
        #expect(controller.renderSize.width > 0 && controller.renderSize.height > 0)
        #expect(fixture.surface.isActiveRenderingSurface)
        #expect(!controller.pictureInPictureShouldClose())
        #expect(controller.pictureInPictureShouldClose())
        try await eventually("PiP restores the inline surface") { !controller.isTransitioning && !controller.isActive }
        #expect(fixture.surface.window === fixture.window)
        #expect(fixture.surface.metalLayer === layer)
        #expect(fixture.surface.isActiveRenderingSurface)
        #expect(presenter.dismissCount == 1)
        #expect(controller.renderSize == .zero)
        content.viewDidAppear()
        #expect(!controller.isActive)
        let final = await fixture.player.lifecycleDiagnostics()
        #expect(final.handlesCreated == initial.handlesCreated)
        #expect(final.loadCommands == initial.loadCommands)
    }

    @Test(arguments: [true, false])
    func `presenter failures report their operation and release view ownership`(starting: Bool) async throws {
        let fixture = PlaybackFixture()
        let presenter = ControlledPiPPresenter()
        let controller = MPVMacPictureInPictureController(player: fixture.player, systemController: presenter)
        defer {
            controller.invalidate()
            fixture.close()
        }
        try await fixture.loadPaused()
        controller.attach(to: fixture.surface)
        var failure: MPVPlayerError?
        controller.onFailure = { failure = $0 }
        presenter.failsToPresent = starting
        presenter.failsToDismiss = !starting
        controller.start()
        if !starting {
            controller.stop()
        }
        try await eventually("presenter failure is reported") { failure != nil }
        #expect(failure == .pictureInPictureFailed(
            operation: starting ? .start : .stop, message: "Controlled presenter failure"
        ))
        #expect(!controller.isActive && !controller.isTransitioning)
        #expect(fixture.surface.window === fixture.window)
        #expect(fixture.surface.isActiveRenderingSurface)
        presenter.failsToPresent = false
        presenter.failsToDismiss = false
        controller.start()
        #expect(controller.isActive)
    }

    @Test(arguments: [true, false])
    func `missing presenter callbacks time out and ignore late appearance`(starting: Bool) async throws {
        let fixture = PlaybackFixture()
        let presenter = ControlledPiPPresenter()
        presenter.appearsImmediately = !starting
        presenter.closesImmediately = false
        let controller = MPVMacPictureInPictureController(player: fixture.player, systemController: presenter)
        defer {
            controller.invalidate()
            fixture.close()
        }
        try await fixture.loadPaused()
        controller.attach(to: fixture.surface)
        var failure: MPVPlayerError?
        controller.onFailure = { failure = $0 }
        controller.start()
        let content = try #require(presenter.content)
        if !starting {
            controller.stop()
        }
        try await eventually("missing system callback times out", timeout: .seconds(7)) { failure != nil }
        #expect(failure == .pictureInPictureTimedOut(operation: starting ? .start : .stop))
        #expect(!controller.isActive && !controller.isTransitioning)
        #expect(fixture.surface.window === fixture.window)
        content.viewDidAppear()
        #expect(!controller.isActive)
    }

    @Test
    func `stalled interface restoration is cancelled and releases the surface`() async throws {
        let fixture = PlaybackFixture()
        let presenter = ControlledPiPPresenter()
        let controller = MPVMacPictureInPictureController(
            player: fixture.player, restorationTimeout: .milliseconds(30), systemController: presenter
        )
        defer {
            controller.invalidate()
            fixture.close()
        }
        try await fixture.loadPaused()
        var failure: MPVPlayerError?
        var cancelled = false
        controller.onFailure = { failure = $0 }
        controller.restoreUserInterface = {
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelled = true }
            return true
        }
        controller.attach(to: fixture.surface)
        controller.start()
        controller.stop()
        try await eventually("restoration watchdog releases PiP") { failure != nil && cancelled }
        #expect(failure == .pictureInPictureTimedOut(operation: .restoreInterface))
        #expect(!controller.isActive && !controller.isTransitioning)
        #expect(presenter.dismissCount == 1)
        #expect(fixture.surface.window === fixture.window)
    }

    @Test
    func `declined interface restoration dismisses without a replacement window`() async throws {
        let fixture = PlaybackFixture()
        let presenter = ControlledPiPPresenter()
        let controller = MPVMacPictureInPictureController(player: fixture.player, systemController: presenter)
        defer {
            controller.invalidate()
            fixture.close()
        }
        try await fixture.loadPaused()
        controller.restoreUserInterface = { false }
        controller.attach(to: fixture.surface)
        controller.start()
        controller.stop()
        try await eventually("declined restoration still dismisses") { !controller.isActive }
        #expect(presenter.replacementWindow == nil)
        #expect(presenter.replacementRect == .zero)
        #expect(fixture.surface.window === fixture.window)
    }

    @Test
    func `replacement surface takes rendering ownership only after dismissal`() async throws {
        let fixture = PlaybackFixture()
        let presenter = ControlledPiPPresenter()
        let controller = MPVMacPictureInPictureController(player: fixture.player, systemController: presenter)
        let replacement = MPVPlatformVideoPlayer(player: fixture.player)
        defer {
            controller.invalidate()
            replacement.detach()
            fixture.close()
        }
        try await fixture.loadPaused()
        controller.attach(to: fixture.surface)
        controller.start()
        fixture.window.contentView = replacement
        replacement.layoutSubtreeIfNeeded()
        controller.attach(to: replacement)
        #expect(controller.hasInlineSource)
        #expect(fixture.surface.isActiveRenderingSurface)
        #expect(!replacement.isActiveRenderingSurface)
        controller.stop()
        try await eventually("replacement receives rendering ownership") { !controller.isActive }
        #expect(replacement.isActiveRenderingSurface)
        #expect(replacement.window === fixture.window)
        #expect(fixture.surface.superview == nil)
        #expect(!fixture.surface.isActiveRenderingSurface)
    }

    @Test
    func `removed replacement and inline hierarchy leave no stale restoration target`() async throws {
        let fixture = PlaybackFixture()
        let presenter = ControlledPiPPresenter()
        let controller = MPVMacPictureInPictureController(player: fixture.player, systemController: presenter)
        let replacement = MPVPlatformVideoPlayer(player: fixture.player)
        defer {
            controller.invalidate()
            replacement.detach()
            fixture.close()
        }
        try await fixture.loadPaused()
        controller.attach(to: fixture.surface)
        controller.start()
        fixture.window.contentView = replacement
        controller.attach(to: replacement)
        controller.detach(from: replacement)
        fixture.window.contentView = NSView()
        #expect(!controller.hasInlineSource)
        controller.stop()
        try await eventually("PiP with no inline target dismisses") { !controller.isActive }
        #expect(presenter.replacementWindow == nil)
        #expect(fixture.surface.superview == nil)
        #expect(!fixture.surface.isActiveRenderingSurface)
    }

    @Test
    func `invalidation cancels pending restoration and ignores delayed callbacks`() async throws {
        let fixture = PlaybackFixture()
        let presenter = ControlledPiPPresenter()
        let controller = MPVMacPictureInPictureController(player: fixture.player, systemController: presenter)
        defer {
            controller.invalidate()
            fixture.close()
        }
        try await fixture.loadPaused()
        let (decisions, continuation) = AsyncStream<Bool>.makeStream()
        defer { continuation.finish() }
        var enteredRestoration = false
        controller.restoreUserInterface = {
            enteredRestoration = true
            for await decision in decisions {
                return decision
            }
            return false
        }
        controller.attach(to: fixture.surface)
        controller.start()
        let content = try #require(presenter.content)
        controller.stop()
        try await eventually("restoration has suspended") { enteredRestoration }
        controller.invalidate()
        continuation.yield(true)
        content.viewDidAppear()
        content.viewDidLayout()
        #expect(presenter.delegate == nil)
        #expect(!controller.isActive && !controller.isTransitioning)
        #expect(controller.onStateChange == nil && controller.restoreUserInterface == nil)
        #expect(fixture.surface.window === fixture.window)
    }

    @Test
    func `system playback and skip requests update the real paused timeline`() async throws {
        let fixture = PlaybackFixture()
        let presenter = ControlledPiPPresenter()
        let controller = MPVMacPictureInPictureController(player: fixture.player, systemController: presenter)
        defer {
            controller.invalidate()
            fixture.close()
        }
        try await fixture.loadPaused()
        controller.attach(to: fixture.surface)
        controller.pictureInPictureSetPlaying(true)
        try await eventually("system play starts native playback") { fixture.player.state == .playing }
        #expect(presenter.playing)
        controller.pictureInPictureSetPlaying(false)
        try await eventually("system pause stops the native clock") { fixture.player.state == .paused }
        #expect(!presenter.playing)
        controller.pictureInPictureSkip(by: -100)
        try await eventually("negative skip clamps to zero") { fixture.player.position < .milliseconds(100) }
        controller.pictureInPictureSkip(by: 2)
        try await eventually("positive skip reaches its destination") { abs(fixture.player.position.seconds - 2) < 0.2 }
        controller.pictureInPictureSkip(by: .nan)
        controller.pictureInPictureSkip(by: .infinity)
        #expect(fixture.player.position.seconds.isFinite)
        controller.prepare()
        #expect(presenter.rate == 0)
        #expect(presenter.duration > 0)
        controller.start()
        fixture.player.stop()
        try await eventually("native stop reaches the player") { fixture.player.state == .stopped }
        controller.synchronizePlaybackState()
        try await eventually("stopping playback dismisses PiP") { !controller.isActive && !controller.isTransitioning }
    }
}

/// Controls only the system boundary; tests use the real player, media, layers,
/// hosting implementation, and delegate callbacks under test.
@MainActor
private final class ControlledPiPPresenter: MPVMacPiPPresenting {
    weak var delegate: (any MPVMacPiPDelegate)?
    var content: NSViewController?
    var appearsImmediately = true
    var closesImmediately = true
    var failsToPresent = false
    var failsToDismiss = false
    var presentCount = 0
    var dismissCount = 0
    weak var replacementWindow: NSWindow?
    var replacementRect = NSRect.zero
    var playing = false
    var rate = 0.0
    var duration = 0.0

    func present(_ content: NSViewController) throws {
        presentCount += 1
        if failsToPresent {
            throw failure
        }
        self.content = content
        if appearsImmediately {
            content.viewDidAppear()
        }
    }

    func dismiss(_ content: NSViewController) throws {
        dismissCount += 1
        if failsToDismiss {
            throw failure
        }
        if closesImmediately {
            delegate?.pictureInPictureWillClose()
            delegate?.pictureInPictureDidClose()
            self.content = nil
        }
    }

    func setReplacementWindow(_ window: NSWindow?, rect: NSRect) {
        replacementWindow = window
        replacementRect = rect
    }

    func updatePlaying(_ playing: Bool, aspectRatio: NSSize) {
        self.playing = playing
    }

    func updatePlaybackRate(_ rate: Double, elapsedTime: TimeInterval, duration: TimeInterval) {
        self.rate = rate
        self.duration = duration
    }

    private var failure: NSError {
        NSError(domain: "MPVUI.PiPTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Controlled presenter failure"])
    }
}
#endif
