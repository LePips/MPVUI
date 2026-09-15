#if os(macOS) && !targetEnvironment(macCatalyst)
import _MPVUIPictureInPicture
import AppKit

/// Boundary to the optional system presenter. Playback and view ownership stay
/// in the controller; the adapter supplies only presentation and its callbacks.
@MainActor
protocol MPVMacPiPPresenting: AnyObject {
    var delegate: (any MPVMacPiPDelegate)? { get set }
    func present(_ content: NSViewController) throws
    func dismiss(_ content: NSViewController) throws
    func setReplacementWindow(_ window: NSWindow?, rect: NSRect)
    func updatePlaying(_ playing: Bool, aspectRatio: NSSize)
    func updatePlaybackRate(_ rate: Double, elapsedTime: TimeInterval, duration: TimeInterval)
}

extension MPVMacPiP: MPVMacPiPPresenting {}

/// Keeps one mpv session and its rendering view alive in the private system host.
/// Public sample-buffer PiP is not the macOS implementation used here.
@MainActor
final class MPVMacPictureInPictureController: NSObject, MPVMacPiPDelegate {
    let isSupported: Bool
    private weak var player: MPVPlayer?
    private let systemController: (any MPVMacPiPPresenting)?
    private weak var sourceSurface: MPVPlatformVideoPlayer?
    private weak var replacementSurface: MPVPlatformVideoPlayer?
    private var hosting: MPVMacPiPViewHosting?
    private var contentController: MPVMacPiPContentController?
    private var restorationTask: Task<Void, Never>?
    private var transitionTimeout: Task<Void, Never>?
    private var isStopping = false
    private var isInvalidated = false
    private var presentationGeneration = 0
    private let restorationTimeoutDuration: Duration

    private(set) var isActive = false
    private(set) var isTransitioning = false
    var presentsVideoOverlay: Bool {
        hosting?.surface.videoOverlay != nil
    }

    var onStateChange: (@MainActor () -> Void)?
    var onFailure: (@MainActor (MPVPlayerError) -> Void)?
    var restoreUserInterface: (@MainActor () async -> Bool)?

    var hasInlineSource: Bool {
        let replacement = replacementSurface.flatMap { $0.window != nil ? $0 : nil }
        let inlineView: NSView? = replacement ?? hosting?.placeholder ?? sourceSurface
        guard let window = inlineView?.window else { return false }
        return window.isVisible || window.isMiniaturized
    }

    var isPossible: Bool {
        guard isSupported, !isInvalidated, !isActive, !isTransitioning,
              let player, let sourceSurface,
              sourceSurface.window != nil,
              sourceSurface.isActiveRenderingSurface,
              sourceSurface.bounds.width > 0, sourceSurface.bounds.height > 0,
              let dimensions = player.mediaInformation.dimensions,
              !dimensions.isEmpty, player.mediaInformation.sourceURL != nil
        else { return false }
        switch player.state {
        case .ready, .playing, .paused, .buffering, .seeking: return true
        default: return false
        }
    }

    var renderSize: CGSize {
        guard let surface = hosting?.surface else { return .zero }
        return MPVRenderSurfaceConfiguration.drawableSize(
            for: surface.bounds.size,
            scale: surface.window?.backingScaleFactor ?? surface.metalLayer.contentsScale
        )
    }

    init(
        player: MPVPlayer,
        restorationTimeout: Duration = .seconds(15),
        systemController: (any MPVMacPiPPresenting)? = MPVMacPiP(checkingAvailability: true)
    ) {
        self.player = player
        restorationTimeoutDuration = max(.milliseconds(1), restorationTimeout)
        self.systemController = systemController
        isSupported = systemController != nil
        super.init()
        systemController?.delegate = self
    }

    isolated deinit {
        invalidate()
    }

    func attach(to surface: MPVPlatformVideoPlayer) {
        guard !isInvalidated, surface.player === player else { return }
        if let presented = hosting?.surface {
            if presented !== surface, surface.window != nil {
                replacementSurface = surface
            }
        } else {
            sourceSurface = surface
        }
        onStateChange?()
    }

    func detach(from surface: MPVPlatformVideoPlayer) {
        if replacementSurface === surface {
            replacementSurface = nil
        }
        guard hosting?.surface !== surface else { return }
        if sourceSurface === surface {
            sourceSurface = nil
        }
        onStateChange?()
    }

    func prepare() {
        synchronizePlaybackState()
    }

    func start() {
        guard !isActive, !isTransitioning, !isInvalidated else { return }
        guard isPossible, let surface = sourceSurface, let systemController else {
            reportFailure(isSupported
                ? .pictureInPictureNotReady
                : .pictureInPictureUnsupported)
            return
        }

        presentationGeneration &+= 1
        let generation = presentationGeneration
        isTransitioning = true
        surface.retainRenderingForPictureInPicture()
        let hosting = MPVMacPiPViewHosting(surface: surface)
        self.hosting = hosting
        let content = MPVMacPiPContentController()
        content.view = hosting.container
        content.onAppear = { [weak self] in
            guard let self, self.presentationGeneration == generation,
                  self.hosting != nil, !self.isStopping, !self.isInvalidated
            else { return }
            self.transitionTimeout?.cancel()
            self.transitionTimeout = nil
            self.isActive = true
            self.isTransitioning = false
            self.hosting?.surface.updateRenderingConfiguration()
            self.hosting?.surface.requestAuthoritativeFinalResize()
            self.onStateChange?()
        }
        content.onLayout = { [weak self] in self?.onStateChange?() }
        contentController = content
        synchronizePlaybackState()
        updateReplacementWindow(bringForward: false)
        onStateChange?()

        do {
            try systemController.present(content)
            // A successful private API call only accepts the request. The
            // content's appearance establishes that the system actually hosts it.
            if !isActive {
                armTransitionTimeout(generation: generation, starting: true)
            }
        } catch {
            reportFailure(.pictureInPictureFailed(operation: .start, message: error.localizedDescription))
            finishPresentation()
        }
    }

    func stop() {
        guard hosting != nil, !isStopping, !isInvalidated else { return }
        isStopping = true
        isTransitioning = true
        transitionTimeout?.cancel()
        let generation = presentationGeneration
        onStateChange?()
        armTransitionTimeout(generation: generation, starting: false, restoring: true)
        let restore = restoreUserInterface
        restorationTask = Task { @MainActor [weak self] in
            // Application code can suspend indefinitely. Do not retain the
            // controller across it; the watchdog can dismiss and release PiP.
            let restored = await restore?() ?? true
            guard !Task.isCancelled, let self, self.presentationGeneration == generation,
                  let content = self.contentController
            else { return }
            if restored {
                self.updateReplacementWindow(bringForward: true)
            } else {
                self.systemController?.setReplacementWindow(nil, rect: .zero)
            }
            do {
                try self.systemController?.dismiss(content)
                if self.hosting != nil {
                    self.armTransitionTimeout(generation: generation, starting: false)
                }
            } catch {
                self.reportFailure(.pictureInPictureFailed(operation: .stop, message: error.localizedDescription))
                self.finishPresentation()
            }
        }
    }

    /// Synchronously tears down ownership when the player/controller is released.
    /// No application restoration callback is needed during final invalidation.
    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        restorationTask?.cancel()
        transitionTimeout?.cancel()
        systemController?.delegate = nil
        contentController?.onAppear = nil
        contentController?.onLayout = nil
        if let contentController {
            try? systemController?.dismiss(contentController)
        }
        finishPresentation()
        sourceSurface = nil
        replacementSurface = nil
        onStateChange = nil
        onFailure = nil
        restoreUserInterface = nil
    }

    func synchronizePlaybackState() {
        guard !isInvalidated, let player else { return }
        systemController?.updatePlaying(
            !player.isPaused,
            aspectRatio: Self.presentationSize(
                dimensions: player.mediaInformation.dimensions,
                rotation: player.mediaInformation.rotation
            )
        )
        systemController?.updatePlaybackRate(
            player.isPaused ? 0 : player.playbackRate,
            elapsedTime: player.position.seconds,
            duration: player.duration.seconds
        )
        switch player.state {
        case .idle, .stopped, .failed:
            if hosting != nil {
                stop()
            }
        default: break
        }
        onStateChange?()
    }

    func pictureInPictureShouldClose() -> Bool {
        if isStopping || isInvalidated {
            return true
        }
        // Restore the app before asking the framework to animate back to it.
        stop()
        return false
    }

    func pictureInPictureWillClose() {
        isTransitioning = true
        onStateChange?()
    }

    func pictureInPictureDidClose() {
        finishPresentation()
    }

    func pictureInPictureSetPlaying(_ playing: Bool) {
        guard let player, !isInvalidated else { return }
        playing ? player.play() : player.pause()
        systemController?.updatePlaying(
            playing,
            aspectRatio: Self.presentationSize(
                dimensions: player.mediaInformation.dimensions,
                rotation: player.mediaInformation.rotation
            )
        )
    }

    func pictureInPictureSkip(by interval: TimeInterval) {
        guard let player, player.isSeekable, interval.isFinite, !isInvalidated else { return }
        player.seek(to: (player.position + .seconds(interval)).clampPositiveOrZero)
    }

    static func presentationSize(dimensions: MPVVideoDimensions?, rotation: Int) -> CGSize {
        let width = max(dimensions?.effectiveWidth ?? 16, 1)
        let height = max(dimensions?.effectiveHeight ?? 9, 1)
        let swapsAxes = abs(rotation % 180) == 90
        return CGSize(width: swapsAxes ? height : width, height: swapsAxes ? width : height)
    }

    private func updateReplacementWindow(bringForward: Bool) {
        let replacement = replacementSurface.flatMap { $0.window != nil ? $0 : nil }
        let inlineView: NSView? = replacement ?? hosting?.placeholder
        guard let inlineView, let window = inlineView.window else {
            systemController?.setReplacementWindow(nil, rect: .zero)
            return
        }
        systemController?.setReplacementWindow(
            window, rect: inlineView.convert(inlineView.bounds, to: nil)
        )
        if bringForward {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func armTransitionTimeout(generation: Int, starting: Bool, restoring: Bool = false) {
        transitionTimeout?.cancel()
        let delay: Duration = restoring ? restorationTimeoutDuration : .seconds(5)
        transitionTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.presentationGeneration == generation,
                  self.hosting != nil, self.isTransitioning else { return }
            self.reportFailure(.pictureInPictureTimedOut(
                operation: restoring ? .restoreInterface : starting ? .start : .stop
            ))
            if let content = self.contentController {
                try? self.systemController?.dismiss(content)
            }
            self.finishPresentation()
        }
    }

    private func finishPresentation() {
        presentationGeneration &+= 1
        transitionTimeout?.cancel()
        transitionTimeout = nil
        restorationTask?.cancel()
        restorationTask = nil
        contentController?.onAppear = nil
        contentController?.onLayout = nil
        let hosted = hosting
        hosting = nil
        let restored = hosted?.restore() ?? false
        contentController?.view = NSView()
        contentController = nil
        hosted?.surface.releaseRenderingFromPictureInPicture()
        isActive = false
        isTransitioning = false
        isStopping = false
        if let replacement = replacementSurface, replacement.window != nil {
            hosted?.surface.detach()
            sourceSurface = replacement
            replacement.activateRenderingSurface()
        } else if restored {
            hosted?.surface.activateRenderingSurface()
            hosted?.surface.requestAuthoritativeFinalResize()
        } else if let player {
            MPVPlayerSurfaceRegistry.shared.activateMostRecentSurface(for: player)
        }
        replacementSurface = nil
        onStateChange?()
    }

    private func reportFailure(_ error: MPVPlayerError) {
        onFailure?(error)
    }
}

@MainActor
private final class MPVMacPiPContentController: NSViewController {
    var onAppear: (@MainActor () -> Void)?
    var onLayout: (@MainActor () -> Void)?

    override func viewDidAppear() {
        super.viewDidAppear()
        onAppear?()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        onLayout?()
    }
}

/// AppKit reparenting is tested separately from availability of the system host.
/// The placeholder preserves inline geometry while the exact Metal view moves.
@MainActor
final class MPVMacPiPViewHosting {
    let surface: MPVPlatformVideoPlayer
    let container: NSView
    let placeholder: NSView
    private weak var sourceSuperview: NSView?
    private weak var sourceWindow: NSWindow?
    private let wasWindowContentView: Bool
    private let originalFrame: NSRect
    private let originalAutoresizingMask: NSView.AutoresizingMask
    private let originalTranslatesAutoresizingMask: Bool
    private var originalConstraints: [NSLayoutConstraint] = []
    private var placeholderConstraints: [NSLayoutConstraint] = []
    private var didRestore = false

    init(surface: MPVPlatformVideoPlayer) {
        self.surface = surface
        originalFrame = surface.frame
        originalAutoresizingMask = surface.autoresizingMask
        originalTranslatesAutoresizingMask = surface.translatesAutoresizingMaskIntoConstraints
        sourceSuperview = surface.superview
        sourceWindow = surface.window
        wasWindowContentView = surface.window?.contentView === surface
        placeholder = NSView(frame: surface.frame)
        placeholder.wantsLayer = true
        placeholder.layer?.backgroundColor = NSColor.black.cgColor
        placeholder.autoresizingMask = originalAutoresizingMask
        placeholder.translatesAutoresizingMaskIntoConstraints = originalTranslatesAutoresizingMask
        container = NSView(frame: surface.bounds)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        // Width/height constraints owned by the surface must move too, or they
        // force the system host to retain the old inline size.
        var ancestor: NSView? = surface
        while let owner = ancestor {
            originalConstraints.append(contentsOf: owner.constraints.filter {
                guard $0.isActive,
                      ($0.firstItem as? NSView) === surface || ($0.secondItem as? NSView) === surface
                else { return false }
                // Constraints to an overlay/child travel with that child and
                // the rendering surface; only inline layout moves to the stub.
                let otherItem = ($0.firstItem as? NSView) === surface ? $0.secondItem : $0.firstItem
                let otherView = (otherItem as? NSView) ?? (otherItem as? NSLayoutGuide)?.owningView
                if let otherView, otherView !== surface, otherView.isDescendant(of: surface) {
                    return false
                }
                return true
            })
            if wasWindowContentView {
                break
            }
            ancestor = owner.superview
        }
        placeholderConstraints = originalConstraints.compactMap { original in
            // SwiftUI also installs framework-owned size constraints whose
            // attributes cannot be passed to NSLayoutConstraint's public
            // initializer. Keep their originals for restoration; the stub's
            // frame is sufficient while those internal constraints are absent.
            guard let firstItem = original.firstItem,
                  Self.isPublicLayoutAttribute(original.firstAttribute),
                  original.firstAttribute != .notAnAttribute,
                  Self.isPublicLayoutAttribute(original.secondAttribute),
                  (original.secondItem == nil) == (original.secondAttribute == .notAnAttribute)
            else { return nil }
            let constraint = NSLayoutConstraint(
                item: (firstItem as? NSView) === surface ? placeholder : firstItem,
                attribute: original.firstAttribute,
                relatedBy: original.relation,
                toItem: (original.secondItem as? NSView) === surface ? placeholder : original.secondItem,
                attribute: original.secondAttribute,
                multiplier: original.multiplier,
                constant: original.constant
            )
            constraint.priority = original.priority
            constraint.identifier = original.identifier
            return constraint
        }
        NSLayoutConstraint.deactivate(originalConstraints)
        if wasWindowContentView {
            sourceWindow?.contentView = placeholder
            NSLayoutConstraint.activate(placeholderConstraints)
        } else if let superview = sourceSuperview {
            superview.addSubview(placeholder, positioned: .below, relativeTo: surface)
            surface.removeFromSuperview()
            NSLayoutConstraint.activate(placeholderConstraints)
        }
        surface.removeFromSuperview()
        surface.translatesAutoresizingMaskIntoConstraints = true
        surface.autoresizingMask = [.width, .height]
        surface.frame = container.bounds
        container.addSubview(surface)
        surface.moveVideoOverlay(to: container)
    }

    @discardableResult
    func restore() -> Bool {
        guard !didRestore else { return surface.window != nil }
        didRestore = true
        surface.moveVideoOverlay(to: nil)
        NSLayoutConstraint.deactivate(placeholderConstraints)
        surface.removeFromSuperview()
        surface.translatesAutoresizingMaskIntoConstraints = originalTranslatesAutoresizingMask
        surface.autoresizingMask = originalAutoresizingMask
        surface.frame = placeholder.frame.isEmpty ? originalFrame : placeholder.frame
        if wasWindowContentView, let sourceWindow, sourceWindow.contentView === placeholder {
            sourceWindow.contentView = surface
            NSLayoutConstraint.activate(originalConstraints.filter(Self.canActivate))
        } else if let superview = placeholder.superview, superview === sourceSuperview {
            superview.addSubview(surface, positioned: .above, relativeTo: placeholder)
            placeholder.removeFromSuperview()
            // A host may have removed its inline hierarchy during PiP. Restore
            // constraints only when both items still share an ancestor.
            NSLayoutConstraint.activate(originalConstraints.filter(Self.canActivate))
        } else {
            placeholder.removeFromSuperview()
        }
        originalConstraints = []
        placeholderConstraints = []
        surface.superview?.layoutSubtreeIfNeeded()
        return surface.window != nil
    }

    private static func canActivate(_ constraint: NSLayoutConstraint) -> Bool {
        func view(_ item: AnyObject?) -> NSView? {
            (item as? NSView) ?? (item as? NSLayoutGuide)?.owningView
        }
        guard let first = view(constraint.firstItem) else { return false }
        guard let secondItem = constraint.secondItem else { return true }
        guard let second = view(secondItem) else { return false }
        var ancestor: NSView? = first
        while let current = ancestor {
            if second === current || second.isDescendant(of: current) {
                return true
            }
            ancestor = current.superview
        }
        return false
    }

    private static func isPublicLayoutAttribute(_ attribute: NSLayoutConstraint.Attribute) -> Bool {
        switch attribute {
        case .notAnAttribute, .left, .right, .top, .bottom, .leading, .trailing,
             .width, .height, .centerX, .centerY, .firstBaseline, .lastBaseline:
            true
        default:
            false
        }
    }
}
#endif
