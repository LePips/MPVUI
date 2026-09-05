import Foundation

/// Mirrors window lifecycle changes for SwiftUI-created playback surfaces.
@MainActor
final class MPVPlayerSurfaceLifecycleObserver: PlatformView {
    private weak var surface: MPVPlatformVideoPlayer?
    private weak var player: MPVPlayer?
    private var shouldRestorePreviousSurface = false

    init(surface: MPVPlatformVideoPlayer, player: MPVPlayer) {
        self.surface = surface
        self.player = player
        super.init(frame: .zero)
        isHidden = true
        #if canImport(UIKit)
        isUserInteractionEnabled = false
        #endif
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    private func platformWillMove(toWindow newWindow: PlatformWindow?) {
        if newWindow == nil {
            shouldRestorePreviousSurface = surface?.isActiveRenderingSurface == true
        }
    }

    private func platformDidMoveToWindow() {
        guard let surface, let player else { return }
        MPVPlayerSurfaceRegistry.shared.surfaceDidMoveToWindow(
            surface,
            player: player,
            isInWindow: window != nil,
            shouldRestorePreviousSurface: shouldRestorePreviousSurface
        )
        if window == nil {
            shouldRestorePreviousSurface = false
        }
    }

    #if os(macOS) && !targetEnvironment(macCatalyst)
    override func viewWillMove(toWindow newWindow: PlatformWindow?) {
        platformWillMove(toWindow: newWindow)
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        platformDidMoveToWindow()
    }
    #elseif canImport(UIKit)
    override func willMove(toWindow newWindow: PlatformWindow?) {
        platformWillMove(toWindow: newWindow)
        super.willMove(toWindow: newWindow)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        platformDidMoveToWindow()
    }
    #endif
}
