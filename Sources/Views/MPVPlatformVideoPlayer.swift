import AVFoundation
import CoreGraphics
import Foundation
import Metal
import Observation
import QuartzCore

#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A native player surface using Metal/MoltenVK or AVFoundation sample buffers.
@MainActor
public final class MPVPlatformVideoPlayer: PlatformView {
    /// The player rendered by this surface.
    public let player: MPVPlayer

    /// The layer consumed by mpv's Metal/MoltenVK video output.
    public var metalLayer: CAMetalLayer {
        guard let layer = layer as? MPVMetalLayer else {
            preconditionFailure("MPVPlatformVideoPlayer must be backed by MPVMetalLayer")
        }
        return layer
    }

    /// Whether this exact surface currently owns the player's render target.
    var isActiveRenderingSurface: Bool {
        player.isRenderSurfaceActive(token: surfaceToken)
    }

    #if os(macOS) && !targetEnvironment(macCatalyst)
    /// Reports an opaque video surface.
    override public var isOpaque: Bool {
        true
    }
    #elseif canImport(UIKit)
    /// The Metal-backed layer type used by the video surface.
    override public class var layerClass: AnyClass {
        MPVMetalLayer.self
    }
    #endif

    private var attachedLayerAddress: Int64?
    private var isRetainedForPictureInPicture = false
    private let surfaceToken = UUID()
    private var surfaceConfiguration: MPVRenderSurfaceConfiguration?
    private var headroomObservationTimer: Timer?
    private var displayRefreshTask: Task<Void, Never>?
    private let notificationCenter: NotificationCenter
    /// Optional current/potential readings for deterministic display tests.
    var wideGamutOverrideForTesting: Bool?
    private lazy var calibratedDisplayProfile = MPVCalibratedDisplayProfile(
        policy: player.configuration.colorManagement.displayProfile
    )
    var edrHeadroomOverrideForTesting: (current: Double, potential: Double)?
    #if os(tvOS)
    private lazy var displayMatchingCoordinator: MPVDisplayMatchingCoordinator = {
        let coordinator = MPVDisplayMatchingCoordinator()
        coordinator.displayModeSwitchDidChange = { [weak self, weak player] switching in
            player?.setDisplaySwitchInProgress(switching)
            self?.scheduleDisplayRefresh()
        }
        return coordinator
    }()
    #endif
    private(set) var videoOverlay: MPVVideoOverlay?
    private(set) var videoOverlayHost: MPVVideoOverlayHostingView?
    private weak var videoOverlayContainer: PlatformView?

    /// Keep the SwiftUI host outside a representable that can be dismantled
    /// while macOS PiP is still visible. Ownership stays with this surface.
    func moveVideoOverlay(to container: PlatformView?) {
        videoOverlayContainer = container
        guard let videoOverlayHost else { return }
        let destination = container ?? self
        videoOverlayHost.removeFromSuperview()
        videoOverlayHost.frame = destination.bounds
        destination.addSubview(videoOverlayHost)
    }

    func setVideoOverlay(_ overlay: MPVVideoOverlay?) {
        videoOverlay = overlay
        if let overlay {
            if let videoOverlayHost {
                videoOverlayHost.setContent(overlay.content)
            } else {
                let host = MPVVideoOverlayHostingView(content: overlay.content)
                let container = videoOverlayContainer ?? self
                host.frame = container.bounds
                #if os(macOS) && !targetEnvironment(macCatalyst)
                host.autoresizingMask = [.width, .height]
                #else
                host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                #endif
                container.addSubview(host)
                videoOverlayHost = host
            }
        } else {
            videoOverlayHost?.removeFromSuperview()
            videoOverlayHost = nil
        }
        player.pictureInPictureOverlayDidChange(self)
    }

    func swiftUISourceWasDismantled() {
        #if os(macOS) && !targetEnvironment(macCatalyst)
        guard isRetainedForPictureInPicture else { return }
        // SwiftUI retires the source graph after dismantle returns. Refresh the
        // independent PiP host on the next turn so it keeps scheduling updates.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRetainedForPictureInPicture,
                  let host = self.videoOverlayHost else { return }
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
        #endif
    }

    #if os(macOS) && !targetEnvironment(macCatalyst)
    private var notificationObservations: [NSObjectProtocol] = []
    private var windowNotificationObservations: [NSObjectProtocol] = []
    private var isAnimatedGeometryTransition = false
    private static let appKitTransitionStateTimeoutNanoseconds: UInt64 =
        600_000_000
    private var appKitTransitionStateTimeoutTask: Task<Void, Never>?
    private var isAppKitContinuousGeometryChange = false
    /// Simulated backing-scale input for deterministic integration tests.
    var displayScaleOverrideForTesting: CGFloat?
    #elseif canImport(UIKit)
    private var notificationObservations: [NSObjectProtocol] = []
    private var registeredTransitionIdentifier: ObjectIdentifier?
    private var lastUncoordinatedLayoutUptimeNanoseconds: UInt64?
    #if os(iOS)
    /// Simulated display inputs for deterministic host-contract tests.
    var displayEnvironmentOverrideForTesting: (scale: CGFloat, potentialEDRHeadroom: CGFloat)?
    #endif
    #endif

    /// Test-only timing injection. Set before the surface is attached.
    var resizeCoordinatorTimingOverrideForTesting:
        MPVRenderSurfaceResizeCoordinator.Timing?

    private lazy var resizeCoordinator = MPVRenderSurfaceResizeCoordinator(
        timing: resizeCoordinatorTimingOverrideForTesting ?? .init(),
        commit: { [weak self] request in
            guard let self,
                  self.attachedLayerAddress == request.layerAddress,
                  self.player.isRenderSurfaceActive(token: self.surfaceToken),
                  MPVMetalLayer.isValidDrawableSize(request.drawableSize),
                  MPVRenderSurfaceResizeCoordinator.layerAddress(
                      of: self.metalLayer
                  ) == request.layerAddress
            else { return false }

            let didResize = await self.player.resizeRenderTargetAndWait(
                token: self.surfaceToken,
                layerAddress: request.layerAddress,
                drawableWidth: Int(request.drawableSize.width),
                drawableHeight: Int(request.drawableSize.height),
                force: request.geometryChangeKind == .final
            )
            guard didResize,
                  self.attachedLayerAddress == request.layerAddress,
                  self.player.isRenderSurfaceActive(token: self.surfaceToken),
                  MPVRenderSurfaceResizeCoordinator.layerAddress(
                      of: self.metalLayer
                  ) == request.layerAddress
            else { return false }
            return true
        },
        emitDiagnostic: { [weak self] snapshot in
            guard let self else { return }
            self.emitSurfaceDiagnostic(self.resizeDiagnosticMessage(snapshot()))
        }
    )

    /// Creates a surface using the existing player's configured video output.
    public init(player: MPVPlayer) {
        self.player = player
        notificationCenter = .default
        super.init(frame: .zero)
        configureBaseLayer()
    }

    /// Isolates the notification boundary so adapter tests do not broadcast
    /// synthetic fullscreen events to AppKit's own private window observers.
    init(player: MPVPlayer, notificationCenter: NotificationCenter) {
        self.player = player
        self.notificationCenter = notificationCenter
        super.init(frame: .zero)
        configureBaseLayer()
    }

    /// Unavailable; create the surface with ``init(player:)``.
    @available(*, unavailable, message: "Use init(player:) to inject an MPVPlayer.")
    override public init(frame _: CGRect) {
        fatalError("Use init(player:) to inject an MPVPlayer")
    }

    /// Unavailable; create the surface with ``init(player:)``.
    @available(*, unavailable, message: "Use init(player:) to inject an MPVPlayer.")
    public required init?(coder _: NSCoder) {
        fatalError("Use init(player:) to inject an MPVPlayer")
    }

    isolated deinit {
        headroomObservationTimer?.invalidate()
        displayRefreshTask?.cancel()
        #if os(macOS) && !targetEnvironment(macCatalyst)
        appKitTransitionStateTimeoutTask?.cancel()
        for observation in notificationObservations + windowNotificationObservations {
            notificationCenter.removeObserver(observation)
        }
        #elseif canImport(UIKit)
        for observation in notificationObservations {
            notificationCenter.removeObserver(observation)
        }
        #endif
    }

    #if os(macOS) && !targetEnvironment(macCatalyst)
    /// Creates the surface's Metal-backed layer.
    override public func makeBackingLayer() -> CALayer {
        MPVMetalLayer()
    }

    /// Updates rendering and display observations after the surface changes windows.
    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindowTransitionObservations()
        platformDidMoveToWindow()
    }

    /// Refreshes rendering for the window's current backing properties.
    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateRenderingConfiguration()
    }

    /// Updates render geometry for the current layout or window transition.
    override public func layout() {
        super.layout()
        let kind: MPVGeometryChangeKind =
            if inLiveResize
                || isAppKitContinuousGeometryChange
            {
                .continuousInteractive
            } else if isAnimatedGeometryTransition {
                .animatedTransition
            } else if NSAnimationContext.current.allowsImplicitAnimation
                || layer?.animation(forKey: "bounds") != nil
                || layer?.animation(forKey: "position") != nil
            {
                .animatedTransition
            } else {
                .discrete
            }
        platformDidLayout(kind: kind)
    }

    /// Begins coordinating render geometry during live resizing.
    override public func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        isAppKitContinuousGeometryChange = true
        resizeCoordinator.beginContinuousInteraction()
    }

    /// Commits the final render geometry after live resizing.
    override public func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        isAppKitContinuousGeometryChange = false
        guard let geometry = currentGeometry() else {
            resizeCoordinator.abortContinuousInteraction()
            return
        }
        resizeCoordinator.endContinuousInteraction(
            finalSize: geometry.drawableSize,
            contentsScale: geometry.contentsScale
        )
    }
    #elseif canImport(UIKit)
    /// Updates rendering after the surface changes windows.
    override public func didMoveToWindow() {
        super.didMoveToWindow()
        platformDidMoveToWindow()
    }

    /// Updates render geometry alongside UIKit layout and transitions.
    override public func layoutSubviews() {
        super.layoutSubviews()
        if let transitionCoordinator = activeTransitionCoordinator(),
           transitionCoordinator.isAnimated
        {
            lastUncoordinatedLayoutUptimeNanoseconds = nil
            platformDidLayout(kind: .animatedTransition)
            registerTransitionCompletionIfNeeded(transitionCoordinator)
        } else if UIView.inheritedAnimationDuration > 0 {
            // SwiftUI and container animations do not always expose a view-
            // controller transition coordinator. Retain the current drawable;
            // the coordinator's bounded fallback supplies the exact final.
            lastUncoordinatedLayoutUptimeNanoseconds = nil
            registeredTransitionIdentifier = nil
            platformDidLayout(kind: .animatedTransition)
        } else {
            registeredTransitionIdentifier = nil
            platformDidLayout(kind: uncoordinatedLayoutGeometryKind())
        }
    }

    #endif

    /// Re-evaluates display capability and synchronizes the layer with mpv.
    public func updateRenderingConfiguration() {
        refreshRenderingConfiguration(updateGeometry: true)
    }

    private func refreshRenderingConfiguration(updateGeometry: Bool) {
        guard window != nil else { return }
        if player.videoOutput == .sampleBuffer {
            updateSampleBufferSurface()
            return
        }
        handleLayerReplacementIfNeeded()
        guard player.isRenderSurfaceActive(token: surfaceToken) else {
            resizeCoordinator.surfaceWasSuperseded()
            #if os(tvOS)
            displayMatchingCoordinator.detach()
            #endif
            return
        }

        var newConfiguration = makeSurfaceConfiguration()
        if !updateGeometry, let previous = surfaceConfiguration {
            // Brightness/metadata polling must not turn an in-flight resize
            // into a discrete geometry request or restart its final boundary.
            newConfiguration = MPVRenderSurfaceConfiguration(
                usesExtendedDynamicRange: newConfiguration.usesExtendedDynamicRange,
                displaySupportsExtendedDynamicRange: newConfiguration.displaySupportsExtendedDynamicRange,
                drawableSize: previous.drawableSize,
                scale: previous.scale,
                outputHeadroom: newConfiguration.outputHeadroom,
                displayCapabilities: newConfiguration.displayCapabilities,
                configuredDynamicRange: newConfiguration.configuredDynamicRange,
                policyFallbackReason: newConfiguration.policyFallbackReason,
                colorConfiguration: newConfiguration.colorConfiguration
            )
        }
        let requiresColorUpdate = surfaceConfiguration.map {
            newConfiguration.requiresRendererReconfiguration(comparedTo: $0)
        } ?? true
        let changesPixelFormat = surfaceConfiguration.map {
            $0.colorConfiguration?.pixelFormat != newConfiguration.colorConfiguration?.pixelFormat
                || $0.usesExtendedDynamicRange != newConfiguration.usesExtendedDynamicRange
        } ?? false

        let requiresGeometryCommit =
            surfaceConfiguration.map {
                newConfiguration.requiresGeometryCommit(comparedTo: $0)
            } ?? true
        if attachedLayerAddress == nil || changesPixelFormat {
            guard currentGeometry() != nil else { return }
        }
        let suspendsRenderer = requiresColorUpdate && attachedLayerAddress != nil
        if suspendsRenderer, let address = attachedLayerAddress {
            guard player.beginRenderColorUpdate(token: surfaceToken, layerAddress: address) else {
                // A loading item has no active VO yet, or an older library
                // lacks the fence. Keep
                // the visible contract intact and retry at the next refresh.
                updateDisplayMatching()
                return
            }
        }
        surfaceConfiguration = newConfiguration

        if attachedLayerAddress == nil {
            guard commitCurrentDrawableSize() else { return }
            attach(using: newConfiguration)
        } else if changesPixelFormat {
            // Retire geometry callbacks for the old swapchain, retaining the
            // layer, decoder, media timebase, and mpv handle.
            #if canImport(UIKit)
            registeredTransitionIdentifier = nil
            lastUncoordinatedLayoutUptimeNanoseconds = nil
            #endif
            resizeCoordinator.rendererConfigurationDidChange()
            guard commitCurrentDrawableSize() else { return }
            attach(using: newConfiguration, synchronousColorUpdate: suspendsRenderer)
        } else {
            if requiresColorUpdate {
                configureLayer(for: newConfiguration, preserveCommittedScale: true)
                updateAttachedRenderTarget(using: newConfiguration, synchronousColorUpdate: suspendsRenderer)
            }
            if requiresGeometryCommit {
                // Keep the attached layer at its committed scale until the
                // coordinator submits the native resize.
                synchronizeRenderTargetAfterGeometryChange(kind: .discrete)
            }
        }
        updateDisplayMatching()
    }

    /// Makes this view the player's active rendering surface.
    public func activateRenderingSurface() {
        guard window != nil else { return }
        startHeadroomObservation()
        let wasActive = player.isRenderSurfaceActive(token: surfaceToken)
        player.activateRenderSurface(token: surfaceToken)
        guard player.isRenderSurfaceActive(token: surfaceToken) else {
            // The PiP presenter retains the old render owner, but needs the
            // new inline view as its restoration destination.
            player.pictureInPictureSurfaceDidAttach(self)
            return
        }
        if !wasActive {
            resizeCoordinator.surfaceWasSuperseded()
            attachedLayerAddress = nil
        }
        updateRenderingConfiguration()
        player.pictureInPictureSurfaceDidAttach(self)
    }

    /// Disconnects mpv before this view or its Metal layer is released.
    public func detach() {
        guard !isRetainedForPictureInPicture else { return }
        headroomObservationTimer?.invalidate()
        headroomObservationTimer = nil
        displayRefreshTask?.cancel()
        displayRefreshTask = nil
        #if os(tvOS)
        displayMatchingCoordinator.detach()
        #endif
        player.pictureInPictureSurfaceDidDetach(self)
        if player.videoOutput == .sampleBuffer,
           player.isRenderSurfaceActive(token: surfaceToken)
        {
            player.sampleBufferDisplayLayer.removeFromSuperlayer()
            player.updateSampleBufferOutput(
                displayCapabilities: .unknown,
                configuredDynamicRange: surfaceConfiguration?.configuredDynamicRange ?? .automatic,
                policyFallbackReason: surfaceConfiguration?.policyFallbackReason == .unsupportedPolicy
                    ? .unsupportedPolicy : nil
            )
        }
        resizeCoordinator.deactivate()
        player.detachRenderTarget(
            token: surfaceToken,
            layerAddress: attachedLayerAddress
        )
        attachedLayerAddress = nil
        surfaceConfiguration = nil
        #if os(macOS) && !targetEnvironment(macCatalyst)
        isAnimatedGeometryTransition = false
        appKitTransitionStateTimeoutTask?.cancel()
        appKitTransitionStateTimeoutTask = nil
        isAppKitContinuousGeometryChange = false
        #elseif canImport(UIKit)
        registeredTransitionIdentifier = nil
        lastUncoordinatedLayoutUptimeNanoseconds = nil
        #endif
    }
}

extension MPVPlatformVideoPlayer {
    /// The player has synchronously retired the previous native target.
    /// Discard cached attachment state without detaching the new backend.
    func videoOutputDidChange() {
        resizeCoordinator.deactivate()
        attachedLayerAddress = nil
        surfaceConfiguration = nil
        #if os(macOS) && !targetEnvironment(macCatalyst)
        endAppKitAnimatedGeometryTransition()
        isAppKitContinuousGeometryChange = false
        #elseif canImport(UIKit)
        registeredTransitionIdentifier = nil
        lastUncoordinatedLayoutUptimeNanoseconds = nil
        #endif
        activateRenderingSurface()
    }

    func retainRenderingForPictureInPicture() {
        guard isActiveRenderingSurface else { return }
        isRetainedForPictureInPicture = true
        player.retainRenderSurfaceForPictureInPicture(token: surfaceToken)
    }

    func releaseRenderingFromPictureInPicture() {
        isRetainedForPictureInPicture = false
        player.releaseRenderSurfaceFromPictureInPicture(token: surfaceToken)
        if window == nil {
            detach()
            MPVPlayerSurfaceRegistry.shared.activateMostRecentSurface(for: player)
        } else {
            activateRenderingSurface()
        }
    }

    private func updateSampleBufferSurface() {
        guard isActiveRenderingSurface, bounds.width > 0, bounds.height > 0 else { return }
        let displayLayer = player.sampleBufferDisplayLayer
        applyWithoutImplicitAnimations {
            if displayLayer.superlayer !== metalLayer {
                displayLayer.removeFromSuperlayer()
                metalLayer.insertSublayer(displayLayer, at: 0)
            }
            displayLayer.frame = bounds
            displayLayer.contentsScale = platformScale
        }
        let configuration = makeSurfaceConfiguration()
        configureNativeLayerPolicy(displayLayer)
        surfaceConfiguration = configuration
        player.updateSampleBufferOutput(
            displayCapabilities: configuration.displayCapabilities,
            configuredDynamicRange: configuration.configuredDynamicRange,
            policyFallbackReason: configuration.policyFallbackReason,
            colorConfiguration: configuration.colorConfiguration
        )
        // A policy may select a backend fallback synchronously.
        guard player.videoOutput == .sampleBuffer else { return }
        player.attachSampleBufferOutput()
        updateDisplayMatching()
    }

    private func configureNativeLayerPolicy(_ displayLayer: AVSampleBufferDisplayLayer) {
        applyWithoutImplicitAnimations {
            if #available(macOS 26.0, iOS 26.0, tvOS 26.0, *) {
                displayLayer.toneMapMode = .ifSupported
                switch player.configuration.hdrPolicy {
                case .automatic: displayLayer.preferredDynamicRange = .automatic
                case .disabled: displayLayer.preferredDynamicRange = .standard
                case .always: displayLayer.preferredDynamicRange = .high
                case .constrained: displayLayer.preferredDynamicRange = .constrainedHigh
                }
            }
        }
    }

    /// Applies one complete renderer/color contract to the shared Metal layer.
    /// Live changes run only inside the native renderer suspension boundary.
    func configureMetalLayer(
        usesExtendedDynamicRange: Bool,
        scale: CGFloat,
        outputHeadroom: Double,
        colorConfiguration: MPVRenderColorConfiguration? = nil
    ) {
        #if os(tvOS)
        let effectiveHDR: Bool = if #available(tvOS 26.0, *) {
            usesExtendedDynamicRange
        } else {
            false
        }
        #else
        let effectiveHDR = usesExtendedDynamicRange
        #endif
        applyWithoutImplicitAnimations {
            metalLayer.contentsScale = max(scale, 1)
            let space = colorConfiguration?.layerColorSpace ?? CGColorSpace(
                name: effectiveHDR ? CGColorSpace.extendedLinearDisplayP3 : CGColorSpace.sRGB
            )!
            let format = colorConfiguration?.pixelFormat ?? (effectiveHDR ? .rgba16Float : .bgra8Unorm)
            (metalLayer as? MPVMetalLayer)?.configureHostColorSpace(space, pixelFormat: format)
            #if os(macOS)
            metalLayer.edrMetadata = nil
            metalLayer.wantsExtendedDynamicRangeContent = effectiveHDR
            #elseif os(iOS)
            metalLayer.edrMetadata = nil
            (metalLayer as? MPVMetalLayer)?.configureExtendedDynamicRangeContent(effectiveHDR)
            #endif
            if #available(macOS 26.0, iOS 26.0, tvOS 26.0, *) {
                metalLayer.preferredDynamicRange = effectiveHDR
                    ? (player.configuration.hdrPolicy == .constrained ? .constrainedHigh : .high)
                    : .standard
                metalLayer.contentsHeadroom = CGFloat(effectiveHDR ? max(outputHeadroom, 1) : 1)
                metalLayer.toneMapMode = effectiveHDR
                    && player.configuration.hdrPolicy == .constrained ? .ifSupported : .never
            }
        }
    }

    var resizeDiagnosticSnapshot: MPVRenderSurfaceResizeCoordinator.DiagnosticSnapshot {
        resizeCoordinator.diagnosticSnapshot
    }

    /// Requests an exact authoritative commit of the current geometry. This
    /// deliberately reaches the native boundary even when the dimensions are
    /// unchanged, which is required for transition trailing-edge confirmation.
    @discardableResult
    func requestAuthoritativeFinalResize() -> Bool {
        guard let geometry = currentGeometry() else { return false }
        return resizeCoordinator.requestResize(
            to: geometry.drawableSize,
            contentsScale: geometry.contentsScale,
            kind: .final
        )
    }

    #if os(macOS) && !targetEnvironment(macCatalyst)
    /// Mirrors AppKit's will-full-screen adapter without broadcasting a
    /// framework notification to unrelated private NSWindow observers.
    func beginAnimatedGeometryTransition() {
        beginAppKitAnimatedGeometryTransition()
    }

    /// Mirrors AppKit's did-full-screen adapter and commits exact final geometry.
    func completeAnimatedGeometryTransition() {
        endAppKitAnimatedGeometryTransition()
        guard let geometry = currentGeometry() else { return }
        resizeCoordinator.completeAnimatedTransition(
            finalSize: geometry.drawableSize,
            contentsScale: geometry.contentsScale
        )
    }
    #endif
}

private extension MPVPlatformVideoPlayer {
    struct Geometry {
        let drawableSize: CGSize
        let contentsScale: CGFloat
    }

    func configureBaseLayer() {
        #if os(macOS) && !targetEnvironment(macCatalyst)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        #else
        backgroundColor = .black
        #endif

        configureMetalLayerForHosting()
        observePlayerRenderingState()
        #if os(macOS) && !targetEnvironment(macCatalyst)
        configureDisplayObservations()
        #elseif canImport(UIKit)
        configureDisplayObservations()
        #endif
        #if canImport(UIKit)
        registerForTraitChanges([
            UITraitDisplayScale.self,
            UITraitDisplayGamut.self,
        ]) { (surface: MPVPlatformVideoPlayer, _: UITraitCollection) in
            surface.updateRenderingConfiguration()
        }
        #endif
    }

    func configureMetalLayerForHosting() {
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.isOpaque = true
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = PlatformColor.black.cgColor
        metalLayer.contentsGravity = .resizeAspectFill
        #if canImport(UIKit)
        // Match MoltenVK 1.4.x's default before it creates the first
        // swapchain; later renderer requests are marshalled by MPVMetalLayer.
        metalLayer.minificationFilter = .nearest
        metalLayer.magnificationFilter = .nearest
        #endif
        metalLayer.presentsWithTransaction = false
        metalLayer.toneMapMode = .never
        #if os(macOS) && !targetEnvironment(macCatalyst)
        metalLayer.displaySyncEnabled = true
        #endif
    }

    func observePlayerRenderingState() {
        withObservationTracking {
            _ = player.mediaInformation
            _ = player.state
            _ = player.videoOutput
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observePlayerRenderingState()
                self.refreshRenderingConfiguration(updateGeometry: false)
            }
        }
    }

    #if os(macOS) && !targetEnvironment(macCatalyst)
    func configureDisplayObservations() {
        let names: [Notification.Name] = [
            NSApplication.didChangeScreenParametersNotification,
            NSScreen.colorSpaceDidChangeNotification,
        ]
        for name in names {
            notificationObservations.append(
                notificationCenter.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.scheduleDisplayRefresh()
                    }
                }
            )
        }
    }
    #elseif canImport(UIKit)
    func configureDisplayObservations() {
        var names: [Notification.Name] = [
            UIScreen.referenceDisplayModeStatusDidChangeNotification,
            UIScreen.modeDidChangeNotification,
            UIScreen.didConnectNotification,
            UIScreen.didDisconnectNotification,
            AVPlayer.eligibleForHDRPlaybackDidChangeNotification,
        ]
        #if os(iOS)
        names.append(UIScreen.brightnessDidChangeNotification)
        #endif
        for name in names {
            notificationObservations.append(
                notificationCenter.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleDisplayRefresh() }
                }
            )
        }
    }
    #endif

    // NSScreen has no current-headroom notification. Sample at a bounded rate
    // while attached, including paused playback and brightness/reference changes.
    // Quantization in the surface contract prevents tiny changes from reaching mpv.
    func startHeadroomObservation() {
        guard headroomObservationTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActiveRenderingSurface else { return }
                self.refreshRenderingConfiguration(updateGeometry: false)
            }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        headroomObservationTimer = timer
    }

    func scheduleDisplayRefresh() {
        guard displayRefreshTask == nil else { return }
        displayRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.displayRefreshTask = nil
            self.refreshRenderingConfiguration(updateGeometry: false)
        }
    }

    func platformDidMoveToWindow() {
        if window == nil {
            if isRetainedForPictureInPicture, player.videoOutput == .sampleBuffer {
                // The system's PiP window does not expose its display route.
                // Keep the request but stop attributing the old inline screen.
                player.updateSampleBufferOutput(
                    displayCapabilities: .unknown,
                    configuredDynamicRange: surfaceConfiguration?.configuredDynamicRange ?? .automatic,
                    policyFallbackReason: surfaceConfiguration?.policyFallbackReason == .unsupportedPolicy
                        ? .unsupportedPolicy : nil
                )
            }
            detach()
        } else {
            startHeadroomObservation()
            activateRenderingSurface()
        }
    }

    func platformDidLayout(kind: MPVGeometryChangeKind) {
        if player.videoOutput == .sampleBuffer {
            updateSampleBufferSurface()
            return
        }
        synchronizeRenderTargetAfterGeometryChange(kind: kind)
    }

    func makeSurfaceConfiguration() -> MPVRenderSurfaceConfiguration {
        let scale = platformScale
        let currentHeadroom: Double
        let potentialHeadroom: Double
        let supportsHDR: Bool
        let supportsWideGamut: Bool
        let systemDisplayProfile: CGColorSpace?
        let displayProfileName: String?
        let supportsCalibratedICC: Bool
        #if os(macOS) && !targetEnvironment(macCatalyst)
        let screen = window?.screen ?? NSScreen.main
        supportsWideGamut = wideGamutOverrideForTesting ?? screen?.colorSpace?.cgColorSpace?.isWideGamutRGB ?? false
        systemDisplayProfile = screen?.colorSpace?.cgColorSpace
        displayProfileName = screen?.colorSpace?.localizedName
        supportsCalibratedICC = true
        currentHeadroom = edrHeadroomOverrideForTesting?.current
            ?? Double(screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
        potentialHeadroom = edrHeadroomOverrideForTesting?.potential
            ?? Double(screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1)
        supportsHDR = potentialHeadroom > 1
        #else
        let screen = window?.windowScene?.screen ?? window?.screen
        supportsWideGamut = wideGamutOverrideForTesting ?? (traitCollection.displayGamut == .P3)
        systemDisplayProfile = nil
        displayProfileName = supportsWideGamut ? "Display P3" : "sRGB"
        supportsCalibratedICC = false
        #if os(iOS)
        let legacyPotential = displayEnvironmentOverrideForTesting.map { Double($0.potentialEDRHeadroom) }
        #else
        let legacyPotential: Double? = nil
        #endif
        currentHeadroom = edrHeadroomOverrideForTesting?.current
            ?? legacyPotential ?? Double(screen?.currentEDRHeadroom ?? 1)
        potentialHeadroom = edrHeadroomOverrideForTesting?.potential
            ?? legacyPotential ?? Double(screen?.potentialEDRHeadroom ?? 1)
        #if os(tvOS)
        // Eligibility includes a connected route that can switch to HDR. It is
        // capability evidence, not evidence of the current HDMI presentation.
        supportsHDR = potentialHeadroom > 1 || AVPlayer.eligibleForHDRPlayback
        #else
        supportsHDR = potentialHeadroom > 1
        #endif
        #endif
        let supportsLayerPolicy: Bool = if #available(macOS 26.0, iOS 26.0, tvOS 26.0, *) {
            true
        } else {
            false
        }
        #if os(tvOS)
        let supportsMetalHDR = supportsLayerPolicy
        #else
        let supportsMetalHDR = true
        #endif
        let preservesHDRWhileOpening = player.state == .loading
            && surfaceConfiguration?.usesExtendedDynamicRange == true
        let policy = MPVHDRSurfacePolicy(
            policy: player.configuration.hdrPolicy,
            native: player.videoOutput == .sampleBuffer,
            supportsLayerPolicy: supportsLayerPolicy,
            supportsMetalHDR: supportsMetalHDR,
            displaySupportsHDR: supportsHDR,
            sourceIsHDR: player.mediaInformation.hdr.isHDRContent || preservesHDRWhileOpening
        )
        let capabilities = MPVDisplayCapabilities(
            hdrSupport: supportsHDR ? .supported : .unsupported,
            currentEDRHeadroom: currentHeadroom,
            potentialEDRHeadroom: potentialHeadroom,
            supportsWideGamut: supportsWideGamut,
            displayProfileName: displayProfileName
        )
        let colorConfiguration = MPVRenderColorConfiguration.resolve(
            configuration: player.configuration,
            native: player.videoOutput == .sampleBuffer,
            usesExtendedDynamicRange: policy.usesExtendedDynamicRange,
            outputHeadroom: capabilities.currentEDRHeadroom ?? 1,
            supportsWideGamut: supportsWideGamut,
            systemDisplayProfile: systemDisplayProfile,
            displayProfileName: displayProfileName,
            calibratedProfile: calibratedDisplayProfile,
            supportsCalibratedICC: supportsCalibratedICC
        )
        return MPVRenderSurfaceConfiguration(
            usesExtendedDynamicRange: policy.usesExtendedDynamicRange,
            displaySupportsExtendedDynamicRange: supportsHDR,
            drawableSize: drawableSize(for: scale),
            scale: scale,
            outputHeadroom: policy.usesExtendedDynamicRange ? currentHeadroom : 1,
            displayCapabilities: capabilities,
            configuredDynamicRange: policy.dynamicRange,
            policyFallbackReason: policy.fallbackReason,
            colorConfiguration: colorConfiguration
        )
    }

    func configureLayer(
        for configuration: MPVRenderSurfaceConfiguration,
        preserveCommittedScale: Bool = false
    ) {
        configureMetalLayer(
            usesExtendedDynamicRange: configuration.usesExtendedDynamicRange,
            scale: preserveCommittedScale ? metalLayer.contentsScale : configuration.scale,
            outputHeadroom: configuration.outputHeadroom,
            colorConfiguration: configuration.colorConfiguration
        )
    }

    func rawGeometry() -> Geometry {
        let scale = max(surfaceConfiguration?.scale ?? platformScale, 1)
        return Geometry(
            drawableSize: drawableSize(for: scale),
            contentsScale: scale
        )
    }

    func drawableSize(for scale: CGFloat) -> CGSize {
        MPVRenderSurfaceConfiguration.drawableSize(
            for: bounds.size,
            scale: scale
        )
    }

    func currentGeometry() -> Geometry? {
        let geometry = rawGeometry()
        guard MPVMetalLayer.isValidDrawableSize(geometry.drawableSize) else {
            return nil
        }
        return geometry
    }

    var platformScale: CGFloat {
        #if os(macOS) && !targetEnvironment(macCatalyst)
        max(
            displayScaleOverrideForTesting
                ?? window?.backingScaleFactor
                ?? 1,
            1
        )
        #elseif os(iOS)
        max(displayEnvironmentOverrideForTesting?.scale ?? window?.screen.scale ?? contentScaleFactor, 1)
        #else
        max(window?.screen.scale ?? contentScaleFactor, 1)
        #endif
    }

    @discardableResult
    func commitCurrentDrawableSize() -> Bool {
        guard let geometry = currentGeometry() else { return false }
        applyWithoutImplicitAnimations {
            metalLayer.contentsScale = geometry.contentsScale
            metalLayer.drawableSize = geometry.drawableSize
        }
        return true
    }

    func attach(using configuration: MPVRenderSurfaceConfiguration, synchronousColorUpdate: Bool = false) {
        // `NSView` can replace its backing layer before the first attachment;
        // make host policy idempotent for every concrete layer we hand to mpv.
        configureMetalLayerForHosting()
        configureLayer(for: configuration)
        let drawableSize = metalLayer.drawableSize
        guard MPVMetalLayer.isValidDrawableSize(drawableSize) else { return }

        let address = MPVRenderSurfaceResizeCoordinator.layerAddress(of: metalLayer)
        attachedLayerAddress = address
        resizeCoordinator.activate(
            layer: metalLayer,
            layerAddress: address,
            contentsScale: configuration.scale,
            committedSize: drawableSize
        )
        updateAttachedRenderTarget(using: configuration, synchronousColorUpdate: synchronousColorUpdate)
        emitSurfaceDiagnostic(
            "attach committed=\(drawableSize) observed=\(metalLayer.drawableSize) "
                + "scale=\(metalLayer.contentsScale) hdr="
                + "\(configuration.usesExtendedDynamicRange)"
        )
    }

    func updateAttachedRenderTarget(using configuration: MPVRenderSurfaceConfiguration, synchronousColorUpdate: Bool = false) {
        guard let address = attachedLayerAddress else { return }
        let drawableSize = metalLayer.drawableSize
        player.attachRenderTarget(
            token: surfaceToken,
            layerAddress: address,
            layerOwner: metalLayer,
            drawableWidth: Int(drawableSize.width),
            drawableHeight: Int(drawableSize.height),
            usesExtendedDynamicRange: configuration.usesExtendedDynamicRange,
            displaySupportsExtendedDynamicRange:
            configuration.displaySupportsExtendedDynamicRange,
            outputHeadroom: configuration.outputHeadroom,
            displayCapabilities: configuration.displayCapabilities,
            configuredDynamicRange: configuration.configuredDynamicRange,
            policyFallbackReason: configuration.policyFallbackReason,
            colorConfiguration: configuration.colorConfiguration,
            synchronousColorUpdate: synchronousColorUpdate
        )
    }

    func updateDisplayMatching() {
        #if os(tvOS)
        let outputUsesHDR = player.videoOutput == .sampleBuffer
            ? player.configuration.hdrPolicy != .disabled
            : surfaceConfiguration?.usesExtendedDynamicRange == true
        displayMatchingCoordinator.update(
            window: window,
            media: player.mediaInformation,
            mediaGeneration: player.mediaGeneration,
            state: player.state,
            isActive: isActiveRenderingSurface,
            outputUsesHDR: outputUsesHDR
        )
        #endif
    }

    func synchronizeRenderTargetAfterGeometryChange(
        kind: MPVGeometryChangeKind
    ) {
        if handleLayerReplacementIfNeeded() {
            updateRenderingConfiguration()
            return
        }
        guard window != nil,
              player.isRenderSurfaceActive(token: surfaceToken),
              let configuration = surfaceConfiguration
        else { return }

        let geometry = rawGeometry()
        guard MPVMetalLayer.isValidDrawableSize(geometry.drawableSize) else {
            resizeCoordinator.requestResize(
                to: geometry.drawableSize,
                contentsScale: geometry.contentsScale,
                kind: kind
            )
            return
        }

        if attachedLayerAddress == nil {
            commitCurrentDrawableSize()
            attach(using: configuration)
            return
        }

        resizeCoordinator.requestResize(
            to: geometry.drawableSize,
            contentsScale: geometry.contentsScale,
            kind: kind
        )
    }

    @discardableResult
    func handleLayerReplacementIfNeeded() -> Bool {
        guard let attachedLayerAddress else { return false }
        let currentLayerAddress = MPVRenderSurfaceResizeCoordinator.layerAddress(
            of: metalLayer
        )
        guard currentLayerAddress != attachedLayerAddress else { return false }

        #if canImport(UIKit)
        registeredTransitionIdentifier = nil
        lastUncoordinatedLayoutUptimeNanoseconds = nil
        #endif
        resizeCoordinator.rendererConfigurationDidChange()
        player.detachRenderTargetSynchronously(
            token: surfaceToken,
            layerAddress: attachedLayerAddress
        )
        self.attachedLayerAddress = nil
        configureMetalLayerForHosting()
        return true
    }

    func applyWithoutImplicitAnimations(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    func resizeDiagnosticMessage(
        _ snapshot: MPVRenderSurfaceResizeCoordinator.DiagnosticSnapshot
    ) -> String {
        let inFlight =
            snapshot.inFlight.map {
                "\($0.identifier):\($0.drawableSize)"
            } ?? "nil"
        return
            "event=\(snapshot.event.rawValue) token=\(surfaceToken) "
                + "requested=\(String(describing: snapshot.latestRequestedDrawableSize)) "
                + "pending=\(String(describing: snapshot.pendingDrawableSize)) "
                + "inFlight=\(inFlight) committed="
                + "\(String(describing: snapshot.committedDrawableSize)) failed="
                + "\(String(describing: snapshot.failedDrawableSize)) observed="
                + "\(String(describing: snapshot.observedDrawableSize)) scale="
                + "\(String(describing: snapshot.contentsScale)) kind="
                + "\(String(describing: snapshot.geometryChangeKind?.rawValue)) "
                + "latencyNs=\(String(describing: snapshot.resizeLatencyNanoseconds)) "
                + "generation=\(snapshot.surfaceGeneration) layer="
                + "\(String(describing: snapshot.activeLayerAddress)) hdr="
                + "\(surfaceConfiguration?.usesExtendedDynamicRange == true)"
    }

    func emitSurfaceDiagnostic(_ message: @autoclosure () -> String) {
        player.emitRenderSurfaceDiagnostic(message())
    }

    #if os(macOS) && !targetEnvironment(macCatalyst)
    func configureWindowTransitionObservations() {
        endAppKitAnimatedGeometryTransition()
        for observation in windowNotificationObservations {
            notificationCenter.removeObserver(observation)
        }
        windowNotificationObservations.removeAll()
        guard let window else { return }

        let center = notificationCenter
        windowNotificationObservations.append(
            center.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateRenderingConfiguration()
                }
            }
        )
        for name in [
            NSWindow.willEnterFullScreenNotification,
            NSWindow.willExitFullScreenNotification,
        ] {
            windowNotificationObservations.append(
                center.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.beginAnimatedGeometryTransition()
                    }
                }
            )
        }
        for name in [
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
        ] {
            windowNotificationObservations.append(
                center.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.completeAnimatedGeometryTransition()
                    }
                }
            )
        }
    }

    func beginAppKitAnimatedGeometryTransition() {
        guard let window else { return }
        isAnimatedGeometryTransition = true
        appKitTransitionStateTimeoutTask?.cancel()

        let windowIdentifier = ObjectIdentifier(window)
        appKitTransitionStateTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: Self.appKitTransitionStateTimeoutNanoseconds
            )
            guard !Task.isCancelled,
                  let self,
                  self.window.map(ObjectIdentifier.init) == windowIdentifier
            else { return }

            self.appKitTransitionStateTimeoutTask = nil
            self.isAnimatedGeometryTransition = false
        }
    }

    func endAppKitAnimatedGeometryTransition() {
        appKitTransitionStateTimeoutTask?.cancel()
        appKitTransitionStateTimeoutTask = nil
        isAnimatedGeometryTransition = false
    }
    #elseif canImport(UIKit)
    func uncoordinatedLayoutGeometryKind() -> MPVGeometryChangeKind {
        let now = DispatchTime.now().uptimeNanoseconds
        defer { lastUncoordinatedLayoutUptimeNanoseconds = now }
        guard let previous = lastUncoordinatedLayoutUptimeNanoseconds,
              now >= previous,
              now - previous <= 100_000_000
        else {
            return .discrete
        }
        return .continuousInteractive
    }

    func activeTransitionCoordinator() -> UIViewControllerTransitionCoordinator? {
        var responder: UIResponder? = self
        while let current = responder {
            if let viewController = current as? UIViewController,
               let coordinator = viewController.transitionCoordinator
            {
                return coordinator
            }
            responder = current.next
        }
        return window?.rootViewController?.transitionCoordinator
    }

    func registerTransitionCompletionIfNeeded(
        _ coordinator: UIViewControllerTransitionCoordinator
    ) {
        let identifier = ObjectIdentifier(coordinator as AnyObject)
        guard registeredTransitionIdentifier != identifier else { return }
        registeredTransitionIdentifier = identifier

        let registered = coordinator.animate(alongsideTransition: nil) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      self.registeredTransitionIdentifier == identifier
                else { return }
                self.registeredTransitionIdentifier = nil
                guard let geometry = self.currentGeometry() else { return }
                self.resizeCoordinator.completeAnimatedTransition(
                    finalSize: geometry.drawableSize,
                    contentsScale: geometry.contentsScale
                )
            }
        }
        if !registered {
            registeredTransitionIdentifier = nil
        }
    }
    #endif
}
