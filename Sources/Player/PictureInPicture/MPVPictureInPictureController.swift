import CoreGraphics
import Observation

/// Picture-in-picture controls accessed through ``MPVPlayer/pictureInPicture``.
///
/// iOS requires `.sampleBuffer` output and the native-output Libmpv build.
/// macOS uses private PIP.framework APIs; avoid this presenter in public-API-only apps.
/// tvOS and Mac Catalyst are unsupported.
///
/// With the player's video view attached, enable a SwiftUI button when PiP is ready:
///
/// ```swift
/// Button("Start Picture in Picture") {
///     player.pictureInPicture.start()
/// }
/// .disabled(!player.pictureInPicture.isPossible || player.pictureInPicture.isTransitioning)
/// ```
@MainActor
@Observable
public final class MPVPictureInPictureController {
    /// Whether the platform and video output support picture in picture.
    public private(set) var isSupported = false
    /// Whether picture in picture can start for the current video.
    public private(set) var isPossible = false
    /// Whether video is currently presented in picture in picture.
    public private(set) var isActive = false
    /// Whether picture in picture is starting or stopping.
    public private(set) var isTransitioning = false
    /// Whether the system has suspended picture-in-picture playback.
    public private(set) var isSuspended = false
    /// The current picture-in-picture render size.
    public private(set) var renderSize: CGSize = .zero
    /// Whether the custom video overlay is hosted or accepted for native PiP
    /// composition. iOS cannot composite overlays onto native Dolby Vision RPU frames.
    public private(set) var isVideoOverlayActive = false
    /// The most recent picture-in-picture failure.
    public private(set) var lastError: MPVPlayerError?

    /// Restore the player's interface before returning `true`.
    /// By default restoration succeeds only if the inline view is in a window.
    @ObservationIgnored
    public var restoreUserInterface: (@MainActor () async -> Bool)?

    /// Let iOS start PiP when leaving the app, when system settings permit it.
    public var allowsAutomaticStartFromInline = false {
        didSet {
            #if os(iOS) && !targetEnvironment(macCatalyst)
            sampleBufferController?.allowsAutomaticStartFromInline = allowsAutomaticStartFromInline
            #endif
        }
    }

    @ObservationIgnored
    private weak var player: MPVPlayer?
    @ObservationIgnored
    private weak var surface: MPVPlatformVideoPlayer?
    #if os(iOS) && !targetEnvironment(macCatalyst)
    @ObservationIgnored
    private var sampleBufferController: MPVSampleBufferPictureInPictureController?
    @ObservationIgnored
    private var overlayRenderer: MPVVideoOverlayRenderer?
    @ObservationIgnored
    private var overlaySurface: MPVPlatformVideoPlayer?
    @ObservationIgnored
    private var overlayLayoutWidth: CGFloat?
    @ObservationIgnored
    private var overlayDisplayScale: CGFloat = 2
    @ObservationIgnored
    private var isNativeRendering = false
    @ObservationIgnored
    private var overlayMediaInformation: MPVMediaInformation?
    #elseif os(macOS)
    @ObservationIgnored
    private var macController: MPVMacPictureInPictureController?
    #endif

    init(player: MPVPlayer) {
        self.player = player
        #if os(iOS) && !targetEnvironment(macCatalyst)
        configureSampleBufferController(for: player)
        #elseif os(macOS)
        let controller = MPVMacPictureInPictureController(player: player)
        macController = controller
        isSupported = controller.isSupported
        controller.onStateChange = { [weak self] in self?.updateMacState() }
        controller.onFailure = { [weak self] error in self?.lastError = error }
        controller.restoreUserInterface = { [weak self] in await self?.restoreInterface() ?? false }
        #endif
    }

    isolated deinit {
        invalidate()
    }

    /// Retire AVKit/AppKit before the player tears down its native output,
    /// including when an application separately retains this facade.
    func invalidate() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        sampleBufferController?.invalidate()
        setNativeRendering(false)
        #elseif os(macOS)
        macController?.invalidate()
        #endif
        player = nil
        surface = nil
        isSupported = false
        isPossible = false
        isActive = false
        isTransitioning = false
        isSuspended = false
        renderSize = .zero
        isVideoOverlayActive = false
    }

    /// Preserve this public facade and its callbacks across a per-file fallback.
    /// macOS hosts the entire view and can keep presenting after a backend change.
    func videoOutputWillChange() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        sampleBufferController?.invalidate()
        setNativeRendering(false)
        sampleBufferController = nil
        isSupported = false
        isPossible = false
        isActive = false
        isTransitioning = false
        isSuspended = false
        renderSize = .zero
        lastError = nil
        #endif
    }

    func videoOutputDidChange() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if let player {
            configureSampleBufferController(for: player)
        }
        #endif
        refreshPlaybackState()
    }

    /// Request PiP after `isPossible` becomes true. Errors are observable.
    public func start() {
        guard isSupported else {
            lastError = .pictureInPictureUnsupported
            return
        }
        lastError = nil
        #if os(iOS) && !targetEnvironment(macCatalyst)
        sampleBufferController?.start()
        #elseif os(macOS)
        macController?.start()
        #endif
    }

    /// Requests that picture in picture close.
    public func stop() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        sampleBufferController?.stop()
        #elseif os(macOS)
        macController?.stop()
        #endif
    }

    /// Stops active or transitioning picture in picture, or requests a start.
    public func toggle() {
        if isActive || isTransitioning {
            stop()
        } else {
            start()
        }
    }

    /// Clears the last picture-in-picture failure.
    public func clearLastError() {
        lastError = nil
        #if os(iOS) && !targetEnvironment(macCatalyst)
        sampleBufferController?.clearLastError()
        #endif
    }

    func attach(to surface: MPVPlatformVideoPlayer) {
        self.surface = surface
        #if os(macOS)
        macController?.attach(to: surface)
        #endif
        refreshPlaybackState()
    }

    func detach(from surface: MPVPlatformVideoPlayer) {
        if self.surface === surface {
            self.surface = nil
        }
        #if os(macOS)
        macController?.detach(from: surface)
        #endif
        refreshPlaybackState()
    }

    func refreshPlaybackState() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        sampleBufferController?.refreshPlaybackState()
        refreshNativeOverlayGeometry()
        #elseif os(macOS)
        macController?.synchronizePlaybackState()
        updateMacState()
        #endif
    }

    func overlayDidChange(on surface: MPVPlatformVideoPlayer) {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if isNativeRendering, overlaySurface === surface {
            updateNativeOverlay()
        }
        #elseif os(macOS)
        updateMacState()
        #endif
    }

    private func restoreInterface() async -> Bool {
        if let restoreUserInterface {
            return await restoreUserInterface()
        }
        #if os(macOS)
        return macController?.hasInlineSource ?? false
        #else
        return surface?.window != nil
        #endif
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    private func configureSampleBufferController(for player: MPVPlayer) {
        guard player.videoOutput == .sampleBuffer else { return }
        let controller = MPVSampleBufferPictureInPictureController(
            player: player,
            displayLayer: player.sampleBufferDisplayLayer,
            onStateChange: { [weak self] state in
                guard let self else { return }
                self.isSupported = state.isSupported
                self.isPossible = state.isPossible
                self.isActive = state.isActive
                self.isTransitioning = state.isStarting || state.isStopping
                self.isSuspended = state.isSuspended
                self.lastError = state.lastError
                self.updateRenderSize(state.renderSize)
            },
            restoreUserInterface: { [weak self] in await self?.restoreInterface() ?? false },
            onRenderingModeChange: { [weak self] enabled in
                self?.setNativeRendering(enabled)
            }
        )
        controller.allowsAutomaticStartFromInline = allowsAutomaticStartFromInline
        sampleBufferController = controller
    }

    /// Shared entry point for AVKit's manual/automatic-start and teardown callbacks.
    func setNativeRendering(_ enabled: Bool) {
        if enabled, !isNativeRendering {
            overlaySurface = surface
            let measuredWidth = surface?.videoOverlayHost?.layoutSize.width ?? 0
            let width = measuredWidth > 0 ? measuredWidth : surface?.bounds.width ?? 0
            overlayLayoutWidth = width.isFinite && width > 0 ? width : nil
            overlayDisplayScale = surface?.window?.screen.scale ?? 2
        }
        isNativeRendering = enabled
        if enabled {
            updateNativeOverlay()
        } else {
            removeNativeOverlay()
            overlaySurface = nil
            overlayLayoutWidth = nil
        }
    }

    func updateRenderSize(_ size: CGSize) {
        renderSize = size
        refreshNativeOverlayGeometry()
    }

    private func updateNativeOverlay() {
        guard isNativeRendering, let overlay = overlaySurface?.videoOverlay else {
            removeNativeOverlay()
            return
        }
        if let overlayRenderer {
            overlayRenderer.updateContent(overlay.content)
        } else {
            overlayRenderer = MPVVideoOverlayRenderer(
                content: overlay.content,
                submit: { [weak player] bitmap in
                    await player?.setPictureInPictureOverlay(bitmap) ?? false
                },
                availabilityChanged: { [weak self] accepted in
                    guard let self else { return }
                    self.isVideoOverlayActive = accepted
                    self.overlaySurface?.videoOverlayHost?.isHidden = accepted
                }
            )
        }
        refreshNativeOverlayGeometry()
    }

    private func refreshNativeOverlayGeometry() {
        guard let overlayRenderer, let player else { return }
        let dimensions = player.mediaInformation.dimensions
        var width = CGFloat(dimensions?.effectiveWidth ?? 16)
        var height = CGFloat(dimensions?.effectiveHeight ?? 9)
        if abs(player.mediaInformation.rotation % 180) == 90 {
            swap(&width, &height)
        }
        guard width > 0, height > 0 else { return }
        // Preserve inline text wrapping, even if the source resizes or leaves
        // its window. PiP pixel dimensions affect resolution, never layout.
        let logicalWidth = overlayLayoutWidth ?? 320
        overlayRenderer.updateSize(
            CGSize(width: logicalWidth, height: logicalWidth * height / width),
            displayScale: overlayDisplayScale,
            rasterSize: renderSize
        )
        if overlayMediaInformation != player.mediaInformation {
            overlayMediaInformation = player.mediaInformation
            if let content = overlaySurface?.videoOverlay?.content {
                overlayRenderer.updateContent(content)
            }
        }
    }

    private func removeNativeOverlay() {
        if overlayRenderer != nil {
            overlayRenderer?.invalidate()
            overlayRenderer = nil
            player?.clearPictureInPictureOverlay()
        }
        overlaySurface?.videoOverlayHost?.isHidden = false
        overlayMediaInformation = nil
        isVideoOverlayActive = false
    }
    #endif

    #if os(macOS)
    private func updateMacState() {
        guard let macController else { return }
        isSupported = macController.isSupported
        isPossible = macController.isPossible
        isActive = macController.isActive
        isTransitioning = macController.isTransitioning
        renderSize = macController.renderSize
        isVideoOverlayActive = (isActive || isTransitioning) && macController.presentsVideoOverlay
    }
    #endif
}
