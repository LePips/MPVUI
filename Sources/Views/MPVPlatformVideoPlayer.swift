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

/// The shared native Metal/MoltenVK player surface for macOS, iOS, and tvOS.
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
    override public var isOpaque: Bool {
        true
    }
    #elseif canImport(UIKit)
    override public class var layerClass: AnyClass {
        MPVMetalLayer.self
    }
    #endif

    private var attachedLayerAddress: Int64?
    private let surfaceToken = UUID()
    private var surfaceConfiguration: MPVRenderSurfaceConfiguration?

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
    #if os(iOS)
    private var notificationObservations: [NSObjectProtocol] = []
    #endif
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
            self?.emitResizeDiagnostic(snapshot)
        }
    )

    /// Creates a Metal surface for an existing player.
    public init(player: MPVPlayer) {
        self.player = player
        super.init(frame: .zero)
        configureBaseLayer()
    }

    @available(*, unavailable, message: "Use init(player:) to inject an MPVPlayer.")
    override public init(frame _: CGRect) {
        fatalError("Use init(player:) to inject an MPVPlayer")
    }

    @available(*, unavailable, message: "Use init(player:) to inject an MPVPlayer.")
    public required init?(coder _: NSCoder) {
        fatalError("Use init(player:) to inject an MPVPlayer")
    }

    isolated deinit {
        #if os(macOS) && !targetEnvironment(macCatalyst)
        appKitTransitionStateTimeoutTask?.cancel()
        for observation in notificationObservations + windowNotificationObservations {
            NotificationCenter.default.removeObserver(observation)
        }
        #elseif os(iOS)
        for observation in notificationObservations {
            NotificationCenter.default.removeObserver(observation)
        }
        #endif
    }

    #if os(macOS) && !targetEnvironment(macCatalyst)
    override public func makeBackingLayer() -> CALayer {
        MPVMetalLayer()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindowTransitionObservations()
        platformDidMoveToWindow()
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateRenderingConfiguration()
    }

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

    override public func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        isAppKitContinuousGeometryChange = true
        resizeCoordinator.beginContinuousInteraction()
    }

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
    override public func didMoveToWindow() {
        super.didMoveToWindow()
        platformDidMoveToWindow()
    }

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
        guard window != nil else { return }
        handleLayerReplacementIfNeeded()
        guard player.isRenderSurfaceActive(token: surfaceToken) else {
            resizeCoordinator.surfaceWasSuperseded()
            return
        }

        let newConfiguration = makeSurfaceConfiguration()
        if let previousConfiguration = surfaceConfiguration,
           newConfiguration.requiresRendererReconfiguration(
               comparedTo: previousConfiguration
           )
        {
            detachForSurfaceReconfiguration()
        }

        let requiresGeometryCommit =
            surfaceConfiguration.map {
                newConfiguration.requiresGeometryCommit(comparedTo: $0)
            } ?? true
        surfaceConfiguration = newConfiguration

        if attachedLayerAddress == nil {
            guard commitCurrentDrawableSize() else { return }
            attach(using: newConfiguration)
        } else if requiresGeometryCommit {
            // Keep the attached layer at its committed scale until the
            // coordinator submits the native resize.
            synchronizeRenderTargetAfterGeometryChange(kind: .discrete)
        }
    }

    /// Makes this view the player's active rendering surface.
    public func activateRenderingSurface() {
        guard window != nil else { return }
        let wasActive = player.isRenderSurfaceActive(token: surfaceToken)
        player.activateRenderSurface(token: surfaceToken)
        if !wasActive {
            resizeCoordinator.surfaceWasSuperseded()
            attachedLayerAddress = nil
        }
        updateRenderingConfiguration()
    }

    /// Disconnects mpv before this view or its Metal layer is released.
    public func detach() {
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
    /// Applies one complete renderer/color contract to the shared Metal layer.
    func configureMetalLayer(
        usesExtendedDynamicRange: Bool,
        scale: CGFloat,
        outputHeadroom: Double
    ) {
        applyWithoutImplicitAnimations {
            metalLayer.contentsScale = max(scale, 1)

            #if os(macOS)
            if usesExtendedDynamicRange {
                metalLayer.pixelFormat = .rgba16Float
                metalLayer.colorspace = CGColorSpace(
                    name: CGColorSpace.extendedLinearDisplayP3
                )
                metalLayer.edrMetadata = nil
                metalLayer.wantsExtendedDynamicRangeContent = true
                if #available(macOS 26.0, *) {
                    metalLayer.preferredDynamicRange = .high
                    metalLayer.contentsHeadroom = CGFloat(max(outputHeadroom, 1))
                }
            } else {
                metalLayer.pixelFormat = .bgra8Unorm
                metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
                metalLayer.edrMetadata = nil
                metalLayer.wantsExtendedDynamicRangeContent = false
                if #available(macOS 26.0, *) {
                    metalLayer.preferredDynamicRange = .standard
                    metalLayer.contentsHeadroom = 1
                }
            }
            #elseif os(iOS)
            if usesExtendedDynamicRange {
                metalLayer.pixelFormat = .rgba16Float
                metalLayer.colorspace = CGColorSpace(
                    name: CGColorSpace.extendedLinearDisplayP3
                )
                metalLayer.edrMetadata = nil
                (metalLayer as? MPVMetalLayer)?
                    .configureExtendedDynamicRangeContent(true)
                if #available(iOS 26.0, *) {
                    metalLayer.preferredDynamicRange = .high
                    metalLayer.contentsHeadroom = CGFloat(max(outputHeadroom, 1))
                }
            } else {
                metalLayer.pixelFormat = .bgra8Unorm
                metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
                metalLayer.edrMetadata = nil
                (metalLayer as? MPVMetalLayer)?
                    .configureExtendedDynamicRangeContent(false)
                if #available(iOS 26.0, *) {
                    metalLayer.preferredDynamicRange = .standard
                    metalLayer.contentsHeadroom = 1
                }
            }
            #else
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            #endif
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
        #elseif os(iOS)
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
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observePlayerRenderingState()
                self.updateRenderingConfiguration()
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
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.updateRenderingConfiguration()
                    }
                }
            )
        }
    }
    #elseif os(iOS)
    func configureDisplayObservations() {
        notificationObservations.append(
            NotificationCenter.default.addObserver(
                forName: UIScreen.referenceDisplayModeStatusDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateRenderingConfiguration()
                }
            }
        )
    }
    #endif

    func platformDidMoveToWindow() {
        if window == nil {
            detach()
        } else {
            activateRenderingSurface()
        }
    }

    func platformDidLayout(kind: MPVGeometryChangeKind) {
        synchronizeRenderTargetAfterGeometryChange(kind: kind)
    }

    func makeSurfaceConfiguration() -> MPVRenderSurfaceConfiguration {
        #if os(macOS) && !targetEnvironment(macCatalyst)
        let screen = window?.screen ?? NSScreen.main
        let scale = max(
            displayScaleOverrideForTesting
                ?? window?.backingScaleFactor
                ?? 1,
            1
        )
        let potentialHeadroom = max(
            screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1,
            1
        )
        let displaySupportsHDR = potentialHeadroom > 1
        let useHDR = shouldUseExtendedDynamicRange(
            displaySupportsHDR: displaySupportsHDR
        )
        return MPVRenderSurfaceConfiguration(
            usesExtendedDynamicRange: useHDR,
            displaySupportsExtendedDynamicRange: displaySupportsHDR,
            drawableSize: drawableSize(for: scale),
            scale: scale,
            outputHeadroom: useHDR ? Double(potentialHeadroom) : 1
        )
        #elseif os(iOS)
        let screen = window?.windowScene?.screen
        let scale = max(
            displayEnvironmentOverrideForTesting?.scale
                ?? screen?.scale
                ?? contentScaleFactor,
            1
        )
        let potentialHeadroom = max(
            displayEnvironmentOverrideForTesting?.potentialEDRHeadroom
                ?? screen?.potentialEDRHeadroom
                ?? 1,
            1
        )
        let displaySupportsHDR = potentialHeadroom > 1
        let useHDR = shouldUseExtendedDynamicRange(
            displaySupportsHDR: displaySupportsHDR
        )
        return MPVRenderSurfaceConfiguration(
            usesExtendedDynamicRange: useHDR,
            displaySupportsExtendedDynamicRange: displaySupportsHDR,
            drawableSize: drawableSize(for: scale),
            scale: scale,
            outputHeadroom: useHDR ? Double(potentialHeadroom) : 1
        )
        #else
        let scale = max(window?.screen.scale ?? contentScaleFactor, 1)
        return MPVRenderSurfaceConfiguration(
            usesExtendedDynamicRange: false,
            displaySupportsExtendedDynamicRange: false,
            drawableSize: drawableSize(for: scale),
            scale: scale,
            outputHeadroom: 1
        )
        #endif
    }

    func shouldUseExtendedDynamicRange(displaySupportsHDR: Bool) -> Bool {
        switch player.configuration.hdrPolicy {
        case .automatic:
            let preservesActiveSurfaceWhileOpening =
                player.state == .loading
                    && surfaceConfiguration?.usesExtendedDynamicRange == true
            return displaySupportsHDR
                && (player.mediaInformation.hdr.isHDRContent
                    || preservesActiveSurfaceWhileOpening)
        case .always:
            return displaySupportsHDR
        case .disabled:
            return false
        }
    }

    func configureLayer(for configuration: MPVRenderSurfaceConfiguration) {
        configureMetalLayer(
            usesExtendedDynamicRange: configuration.usesExtendedDynamicRange,
            scale: configuration.scale,
            outputHeadroom: configuration.outputHeadroom
        )
    }

    func detachForSurfaceReconfiguration() {
        #if canImport(UIKit)
        registeredTransitionIdentifier = nil
        lastUncoordinatedLayoutUptimeNanoseconds = nil
        #endif
        resizeCoordinator.rendererConfigurationDidChange()
        guard let attachedLayerAddress else { return }
        player.detachRenderTargetSynchronously(
            token: surfaceToken,
            layerAddress: attachedLayerAddress
        )
        self.attachedLayerAddress = nil
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

    func attach(using configuration: MPVRenderSurfaceConfiguration) {
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
        player.attachRenderTarget(
            token: surfaceToken,
            layerAddress: address,
            layerOwner: metalLayer,
            drawableWidth: Int(drawableSize.width),
            drawableHeight: Int(drawableSize.height),
            usesExtendedDynamicRange: configuration.usesExtendedDynamicRange,
            displaySupportsExtendedDynamicRange:
            configuration.displaySupportsExtendedDynamicRange,
            outputHeadroom: configuration.outputHeadroom
        )
        emitSurfaceDiagnostic(
            "attach committed=\(drawableSize) observed=\(metalLayer.drawableSize) "
                + "scale=\(metalLayer.contentsScale) hdr="
                + "\(configuration.usesExtendedDynamicRange)"
        )
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

    func emitResizeDiagnostic(
        _ snapshot: MPVRenderSurfaceResizeCoordinator.DiagnosticSnapshot
    ) {
        let inFlight =
            snapshot.inFlight.map {
                "\($0.identifier):\($0.drawableSize)"
            } ?? "nil"
        emitSurfaceDiagnostic(
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
        )
    }

    func emitSurfaceDiagnostic(_ message: String) {
        player.emitRenderSurfaceDiagnostic(message)
    }

    #if os(macOS) && !targetEnvironment(macCatalyst)
    func configureWindowTransitionObservations() {
        endAppKitAnimatedGeometryTransition()
        for observation in windowNotificationObservations {
            NotificationCenter.default.removeObserver(observation)
        }
        windowNotificationObservations.removeAll()
        guard let window else { return }

        let center = NotificationCenter.default
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
