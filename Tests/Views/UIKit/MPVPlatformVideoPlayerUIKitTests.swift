#if os(iOS) || os(tvOS)
import CoreGraphics
import Foundation
@testable import MPVUI
import Testing
import UIKit

@Suite(.serialized)
@MainActor
struct MPVPlatformVideoPlayerUIKitTests {
    @Test
    func `transition completion submits latest final once and cancels fallback`() async throws {
        let player = MPVPlayer(
            configuration: .init(
                autoPlay: false,
                hardwareDecoding: .disabled,
                hdrPolicy: .disabled
            )
        )
        let surface = MPVPlatformVideoPlayer(player: player)
        let viewController = TransitionHostingViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        attach(surface, to: viewController, in: window)
        defer { detach(surface, from: viewController, in: window) }

        let attachedLifecycle = await waitForLifecycle(player) {
            $0.handlesCreated == 1
        }
        #expect(attachedLifecycle.handlesCreated == 1)
        let committedBeforeTransition = try #require(
            surface.resizeDiagnosticSnapshot.committedDrawableSize
        )
        let observedBeforeTransition = surface.metalLayer.drawableSize
        let initialOutputSize = MPVRenderOutputSize(
            width: Int(committedBeforeTransition.width),
            height: Int(committedBeforeTransition.height)
        )
        let mediaURL = TestPaths.baselineMedia
        try #require(FileManager.default.fileExists(atPath: mediaURL.path))

        player.load(mediaURL, autoPlay: false)
        try #require(
            await waitForPlayer(player) {
                $0.mediaInformation.dimensions != nil
                    && ($0.state == .ready || $0.state == .paused)
            }
        )
        try #require(player.lastError == nil)
        try #require(
            await waitForRenderOutputSize(initialOutputSize, from: player)
                == initialOutputSize
        )
        try #require(
            await waitForDrawableSize(
                committedBeforeTransition,
                in: surface.metalLayer
            ) == committedBeforeTransition
        )
        // Loading can briefly report ready/paused before buffering and its
        // rendering-state observations arrive. Require stable paused playback
        // and an idle resize coordinator before measuring the transition.
        try #require(await waitForPausedSurfaceToSettle(player, surface: surface))
        let layerBeforeTransition = surface.metalLayer
        let surfaceBeforeTransition = surface.resizeDiagnosticSnapshot
        let layerAddressBeforeTransition = try #require(
            surfaceBeforeTransition.activeLayerAddress
        )
        let generationBeforeTransition = surfaceBeforeTransition.surfaceGeneration
        let stateBeforeTransition = player.state
        let lifecycleBeforeTransition = await player.lifecycleDiagnostics()

        let transitionCoordinator = TestTransitionCoordinator(
            acceptsAnimationRegistration: true
        )
        viewController.suppliedTransitionCoordinator = transitionCoordinator

        resize(surface, to: CGSize(width: 360, height: 240))
        let firstExpectedSize = drawableSize(of: surface)
        let firstSnapshot = surface.resizeDiagnosticSnapshot
        #expect(firstSnapshot.geometryChangeKind == .animatedTransition)
        #expect(firstSnapshot.pendingDrawableSize == firstExpectedSize)
        #expect(firstSnapshot.committedDrawableSize == committedBeforeTransition)
        #expect(firstSnapshot.observedDrawableSize == observedBeforeTransition)
        #expect(firstSnapshot.hasAnimatedFallback)
        #expect(firstSnapshot.finalCommitRequired)
        #expect(firstSnapshot.inFlight == nil)
        #expect(transitionCoordinator.animationRegistrationCount == 1)

        resize(surface, to: CGSize(width: 480, height: 270))
        let latestExpectedSize = drawableSize(of: surface)
        let latestSnapshot = surface.resizeDiagnosticSnapshot
        #expect(latestExpectedSize != firstExpectedSize)
        #expect(latestSnapshot.geometryChangeKind == .animatedTransition)
        #expect(latestSnapshot.pendingDrawableSize == latestExpectedSize)
        #expect(latestSnapshot.committedDrawableSize == committedBeforeTransition)
        #expect(latestSnapshot.observedDrawableSize == observedBeforeTransition)
        #expect(latestSnapshot.hasAnimatedFallback)
        #expect(latestSnapshot.finalCommitRequired)
        #expect(latestSnapshot.inFlight == nil)
        #expect(transitionCoordinator.animationRegistrationCount == 1)

        surface.setNeedsLayout()
        surface.layoutIfNeeded()
        #expect(transitionCoordinator.animationRegistrationCount == 1)
        #expect(
            surface.resizeDiagnosticSnapshot.committedDrawableSize
                == committedBeforeTransition
        )

        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(
            await player.lifecycleDiagnostics().surfaceResizeCommands
                == lifecycleBeforeTransition.surfaceResizeCommands
        )

        transitionCoordinator.completeTransition()
        viewController.suppliedTransitionCoordinator = nil

        let lifecycleAfterCompletion = await waitForLifecycle(player) {
            $0.surfaceResizeCommands
                == lifecycleBeforeTransition.surfaceResizeCommands + 1
        }
        #expect(
            lifecycleAfterCompletion.surfaceResizeCommands
                == lifecycleBeforeTransition.surfaceResizeCommands + 1
        )
        let completedSnapshot = await waitForResizeDiagnostic(surface) {
            $0.committedDrawableSize == latestExpectedSize
                && $0.inFlight == nil
        }
        let expectedOutputSize = MPVRenderOutputSize(
            width: Int(latestExpectedSize.width),
            height: Int(latestExpectedSize.height)
        )
        let finalOutputSize = await waitForRenderOutputSize(
            expectedOutputSize,
            from: player
        )
        let finalLayerSize = await waitForDrawableSize(
            latestExpectedSize,
            in: surface.metalLayer
        )
        #expect(transitionCoordinator.completionInvocationCount == 1)
        #expect(completedSnapshot.geometryChangeKind == .final)
        #expect(completedSnapshot.committedDrawableSize == latestExpectedSize)
        #expect(completedSnapshot.pendingDrawableSize == nil)
        #expect(!completedSnapshot.finalCommitRequired)
        #expect(!completedSnapshot.hasAnimatedFallback)
        #expect(surface.metalLayer === layerBeforeTransition)
        #expect(completedSnapshot.activeLayerAddress == layerAddressBeforeTransition)
        #expect(completedSnapshot.surfaceGeneration == generationBeforeTransition)
        #expect(
            lifecycleAfterCompletion.handlesCreated
                == lifecycleBeforeTransition.handlesCreated
        )
        #expect(
            lifecycleAfterCompletion.handlesDestroyed
                == lifecycleBeforeTransition.handlesDestroyed
        )
        #expect(
            lifecycleAfterCompletion.loadCommands
                == lifecycleBeforeTransition.loadCommands
        )
        #expect(
            lifecycleAfterCompletion.startFileEvents
                == lifecycleBeforeTransition.startFileEvents
        )
        #expect(
            lifecycleAfterCompletion.seekCommands
                == lifecycleBeforeTransition.seekCommands
        )
        #expect(
            lifecycleAfterCompletion.loadingStateTransitions
                == lifecycleBeforeTransition.loadingStateTransitions
        )
        #expect(
            lifecycleAfterCompletion.bufferingStateTransitions
                == lifecycleBeforeTransition.bufferingStateTransitions
        )
        #expect(
            lifecycleAfterCompletion.seekingStateTransitions
                == lifecycleBeforeTransition.seekingStateTransitions
        )
        #expect(finalOutputSize == expectedOutputSize)
        #expect(finalLayerSize == latestExpectedSize)
        #expect(surface.metalLayer.drawableSize == latestExpectedSize)
        #expect(player.mediaInformation.sourceURL == mediaURL)
        #expect(player.state == stateBeforeTransition)

        try await Task.sleep(nanoseconds: 650_000_000)
        #expect(
            await player.lifecycleDiagnostics().surfaceResizeCommands
                == lifecycleAfterCompletion.surfaceResizeCommands
        )
        #expect(player.lastError == nil)
    }

    @Test
    func `failed transition registration falls back to one latest final`() async throws {
        let player = MPVPlayer(
            configuration: .init(autoPlay: false, hdrPolicy: .disabled)
        )
        let surface = MPVPlatformVideoPlayer(player: player)
        let viewController = TransitionHostingViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        attach(surface, to: viewController, in: window)
        defer { detach(surface, from: viewController, in: window) }

        let attachedLifecycle = await waitForLifecycle(player) {
            $0.handlesCreated == 1
        }
        #expect(attachedLifecycle.handlesCreated == 1)
        let lifecycleBeforeTransition = await player.lifecycleDiagnostics()
        let committedBeforeTransition = try #require(
            surface.resizeDiagnosticSnapshot.committedDrawableSize
        )
        let observedBeforeTransition = surface.metalLayer.drawableSize

        let transitionCoordinator = TestTransitionCoordinator(
            acceptsAnimationRegistration: false
        )
        viewController.suppliedTransitionCoordinator = transitionCoordinator

        resize(surface, to: CGSize(width: 480, height: 270))
        let expectedSize = drawableSize(of: surface)
        let transitionSnapshot = surface.resizeDiagnosticSnapshot
        #expect(transitionCoordinator.animationRegistrationCount == 1)
        #expect(transitionCoordinator.storedCompletionCount == 0)
        #expect(transitionSnapshot.geometryChangeKind == .animatedTransition)
        #expect(transitionSnapshot.pendingDrawableSize == expectedSize)
        #expect(transitionSnapshot.committedDrawableSize == committedBeforeTransition)
        #expect(transitionSnapshot.observedDrawableSize == observedBeforeTransition)
        #expect(transitionSnapshot.hasAnimatedFallback)
        #expect(transitionSnapshot.finalCommitRequired)
        #expect(transitionSnapshot.inFlight == nil)

        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(
            await player.lifecycleDiagnostics().surfaceResizeCommands
                == lifecycleBeforeTransition.surfaceResizeCommands
        )

        let lifecycleAfterFallback = await waitForLifecycle(player) {
            $0.surfaceResizeCommands
                == lifecycleBeforeTransition.surfaceResizeCommands + 1
        }
        #expect(
            lifecycleAfterFallback.surfaceResizeCommands
                == lifecycleBeforeTransition.surfaceResizeCommands + 1
        )
        let completedSnapshot = await waitForResizeDiagnostic(surface) {
            $0.committedDrawableSize == expectedSize
                && $0.inFlight == nil
        }
        #expect(completedSnapshot.geometryChangeKind == .final)
        #expect(completedSnapshot.committedDrawableSize == expectedSize)
        #expect(completedSnapshot.pendingDrawableSize == nil)
        #expect(!completedSnapshot.finalCommitRequired)
        #expect(!completedSnapshot.hasAnimatedFallback)
        #expect(transitionCoordinator.completionInvocationCount == 0)
        #expect(
            lifecycleAfterFallback.handlesCreated
                == lifecycleBeforeTransition.handlesCreated
        )
        #expect(
            lifecycleAfterFallback.handlesDestroyed
                == lifecycleBeforeTransition.handlesDestroyed
        )
        #expect(
            lifecycleAfterFallback.loadCommands
                == lifecycleBeforeTransition.loadCommands
        )

        try await Task.sleep(nanoseconds: 650_000_000)
        #expect(
            await player.lifecycleDiagnostics().surfaceResizeCommands
                == lifecycleAfterFallback.surfaceResizeCommands
        )
        #expect(player.lastError == nil)
    }

    #if os(iOS)
    @Test
    func `simulated HDR host contract resizes in place on the same layer`() async throws {
        let player = MPVPlayer(
            configuration: .init(
                autoPlay: true,
                hardwareDecoding: .disabled,
                hdrPolicy: .always
            )
        )
        let surface = MPVPlatformVideoPlayer(player: player)
        // This override exercises only MPVUI's deterministic host contract. It
        // does not claim that the simulator presents real HDR output.
        surface.displayEnvironmentOverrideForTesting = (
            scale: 2,
            potentialEDRHeadroom: 4
        )
        let viewController = TransitionHostingViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        attach(surface, to: viewController, in: window)
        defer { detach(surface, from: viewController, in: window) }

        let attachedLifecycle = await waitForLifecycle(player) {
            $0.handlesCreated == 1
        }
        #expect(attachedLifecycle.handlesCreated == 1)
        let layer = surface.metalLayer
        let attachedSnapshot = surface.resizeDiagnosticSnapshot
        let attachedLayerAddress = try #require(
            attachedSnapshot.activeLayerAddress
        )
        let attachedGeneration = attachedSnapshot.surfaceGeneration

        #expect(layer.pixelFormat == .rgba16Float)
        #expect(layer.contentsScale == 2)

        let mediaURL = TestPaths.baselineMedia
        try #require(FileManager.default.fileExists(atPath: mediaURL.path))
        player.load(mediaURL, autoPlay: true)
        let didLoadMedia = await waitForPlayer(player) {
            $0.mediaInformation.dimensions != nil
                && $0.state == .playing
        }
        try #require(didLoadMedia)
        try #require(player.lastError == nil)
        let initialDrawableSize = try #require(
            attachedSnapshot.committedDrawableSize
        )
        let initialOutputSize = MPVRenderOutputSize(
            width: Int(initialDrawableSize.width),
            height: Int(initialDrawableSize.height)
        )
        try #require(
            await waitForRenderOutputSize(initialOutputSize, from: player)
                == initialOutputSize
        )
        try #require(
            await waitForDrawableSize(initialDrawableSize, in: layer)
                == initialDrawableSize
        )

        let positionBeforeResize = player.position
        let lifecycleBeforeResize = await player.lifecycleDiagnostics()
        var latestLifecycle = lifecycleBeforeResize
        var latestExpectedSize = initialDrawableSize

        // Drive each change through UIKit's transition-completion boundary.
        // This avoids timing heuristics and proves repeated renderer-backed EDR
        // swaps while real playback remains active.
        let resizeFrames = [
            CGSize(width: 480, height: 270),
            CGSize(width: 360, height: 240),
            CGSize(width: 512, height: 288),
            CGSize(width: 400, height: 300),
        ]
        for (index, frameSize) in resizeFrames.enumerated() {
            let commandsBeforeTransition = latestLifecycle.surfaceResizeCommands
            let transitionCoordinator = TestTransitionCoordinator(
                acceptsAnimationRegistration: true
            )
            viewController.suppliedTransitionCoordinator = transitionCoordinator
            resize(surface, to: frameSize)

            latestExpectedSize = drawableSize(of: surface)
            let transitionSnapshot = surface.resizeDiagnosticSnapshot
            #expect(transitionCoordinator.animationRegistrationCount == 1)
            #expect(transitionSnapshot.geometryChangeKind == .animatedTransition)
            #expect(transitionSnapshot.pendingDrawableSize == latestExpectedSize)
            #expect(transitionSnapshot.inFlight == nil)
            #expect(transitionSnapshot.hasAnimatedFallback)
            #expect(
                await player.lifecycleDiagnostics().surfaceResizeCommands
                    == commandsBeforeTransition
            )

            transitionCoordinator.completeTransition()
            viewController.suppliedTransitionCoordinator = nil

            latestLifecycle = await waitForLifecycle(player) {
                $0.surfaceResizeCommands == commandsBeforeTransition + 1
            }
            let resizedSnapshot = await waitForResizeDiagnostic(surface) {
                $0.committedDrawableSize == latestExpectedSize
                    && $0.inFlight == nil
            }
            let expectedOutputSize = MPVRenderOutputSize(
                width: Int(latestExpectedSize.width),
                height: Int(latestExpectedSize.height)
            )
            let resizedOutputSize = await waitForRenderOutputSize(
                expectedOutputSize,
                from: player
            )
            let resizedLayerSize = await waitForDrawableSize(
                latestExpectedSize,
                in: layer
            )

            #expect(
                latestLifecycle.surfaceResizeCommands
                    == lifecycleBeforeResize.surfaceResizeCommands
                    + UInt64(index + 1)
            )
            #expect(transitionCoordinator.completionInvocationCount == 1)
            #expect(!resizedSnapshot.hasAnimatedFallback)
            #expect(!resizedSnapshot.finalCommitRequired)
            #expect(resizedSnapshot.activeLayerAddress == attachedLayerAddress)
            #expect(resizedSnapshot.surfaceGeneration == attachedGeneration)
            #expect(resizedOutputSize == expectedOutputSize)
            #expect(resizedLayerSize == latestExpectedSize)
            #expect(surface.metalLayer === layer)
            #expect(layer.pixelFormat == .rgba16Float)
            #expect(player.state == .playing)
            #expect(player.lastError == nil)
        }

        #expect(surface.metalLayer === layer)
        #expect(layer.pixelFormat == .rgba16Float)
        #expect(
            layer.drawableSize == latestExpectedSize
        )
        #expect(
            latestLifecycle.surfaceResizeCommands
                == lifecycleBeforeResize.surfaceResizeCommands
                + UInt64(resizeFrames.count)
        )
        #expect(
            latestLifecycle.handlesCreated == lifecycleBeforeResize.handlesCreated
        )
        #expect(
            latestLifecycle.handlesDestroyed
                == lifecycleBeforeResize.handlesDestroyed
        )
        #expect(latestLifecycle.loadCommands == lifecycleBeforeResize.loadCommands)
        #expect(
            latestLifecycle.startFileEvents
                == lifecycleBeforeResize.startFileEvents
        )
        #expect(latestLifecycle.seekCommands == lifecycleBeforeResize.seekCommands)
        #expect(
            latestLifecycle.loadingStateTransitions
                == lifecycleBeforeResize.loadingStateTransitions
        )
        #expect(
            latestLifecycle.bufferingStateTransitions
                == lifecycleBeforeResize.bufferingStateTransitions
        )
        #expect(
            latestLifecycle.seekingStateTransitions
                == lifecycleBeforeResize.seekingStateTransitions
        )
        #expect(player.mediaInformation.sourceURL == mediaURL)
        #expect(player.position >= positionBeforeResize)
        #expect(player.state == .playing)
        #expect(!player.bufferStatus.isBuffering)
        #expect(player.lastError == nil)

        try await Task.sleep(nanoseconds: 650_000_000)
        #expect(
            await player.lifecycleDiagnostics().surfaceResizeCommands
                == latestLifecycle.surfaceResizeCommands
        )
    }

    @Test
    func `display HDR loss invalidates stale transition work before reconfiguration`() async throws {
        let player = MPVPlayer(
            configuration: .init(autoPlay: false, hdrPolicy: .always)
        )
        let surface = MPVPlatformVideoPlayer(player: player)
        surface.displayEnvironmentOverrideForTesting = (
            scale: 2,
            potentialEDRHeadroom: 4
        )
        let viewController = TransitionHostingViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        attach(surface, to: viewController, in: window)
        defer { detach(surface, from: viewController, in: window) }

        let attachedLifecycle = await waitForLifecycle(player) {
            $0.handlesCreated == 1
        }
        #expect(attachedLifecycle.handlesCreated == 1)
        let layer = surface.metalLayer
        let attachedSnapshot = surface.resizeDiagnosticSnapshot
        let initialGeneration = attachedSnapshot.surfaceGeneration
        let initialLayerAddress = try #require(
            attachedSnapshot.activeLayerAddress
        )
        #expect(layer.pixelFormat == .rgba16Float)

        let transitionCoordinator = TestTransitionCoordinator(
            acceptsAnimationRegistration: true
        )
        viewController.suppliedTransitionCoordinator = transitionCoordinator
        resize(surface, to: CGSize(width: 480, height: 270))

        let transitionSnapshot = surface.resizeDiagnosticSnapshot
        #expect(transitionCoordinator.animationRegistrationCount == 1)
        #expect(transitionCoordinator.storedCompletionCount == 1)
        #expect(transitionSnapshot.geometryChangeKind == .animatedTransition)
        #expect(transitionSnapshot.hasAnimatedFallback)
        #expect(transitionSnapshot.finalCommitRequired)
        #expect(transitionSnapshot.surfaceGeneration == initialGeneration)

        surface.displayEnvironmentOverrideForTesting = (
            scale: 2,
            potentialEDRHeadroom: 1
        )
        NotificationCenter.default.post(
            name: UIScreen.referenceDisplayModeStatusDidChangeNotification,
            object: nil
        )

        let reconfiguredLifecycle = await waitForLifecycle(player) {
            $0.handlesCreated == attachedLifecycle.handlesCreated + 1
                && $0.handlesDestroyed
                == attachedLifecycle.handlesDestroyed + 1
        }
        let reconfiguredSnapshot = surface.resizeDiagnosticSnapshot
        let reconfiguredGeneration = reconfiguredSnapshot.surfaceGeneration
        let expectedSize = CGSize(width: 960, height: 540)

        #expect(surface.metalLayer === layer)
        #expect(layer.pixelFormat == .bgra8Unorm)
        #expect(layer.contentsScale == 2)
        #expect(layer.drawableSize == expectedSize)
        #expect(reconfiguredGeneration > initialGeneration)
        #expect(reconfiguredSnapshot.activeLayerAddress == initialLayerAddress)
        #expect(reconfiguredSnapshot.committedDrawableSize == expectedSize)
        #expect(reconfiguredSnapshot.pendingDrawableSize == nil)
        #expect(reconfiguredSnapshot.inFlight == nil)
        #expect(!reconfiguredSnapshot.hasAnimatedFallback)
        #expect(!reconfiguredSnapshot.finalCommitRequired)
        #expect(
            reconfiguredLifecycle.handlesCreated
                == attachedLifecycle.handlesCreated + 1
        )
        #expect(
            reconfiguredLifecycle.handlesDestroyed
                == attachedLifecycle.handlesDestroyed + 1
        )
        #expect(
            reconfiguredLifecycle.loadCommands == attachedLifecycle.loadCommands
        )
        #expect(
            reconfiguredLifecycle.surfaceResizeCommands
                == attachedLifecycle.surfaceResizeCommands
        )

        // The retained UIKit coordinator still invokes its old closure, but
        // the reconfiguration reset must make that closure and its fallback
        // incapable of resizing the replacement surface generation.
        transitionCoordinator.completeTransition()
        viewController.suppliedTransitionCoordinator = nil
        try await Task.sleep(nanoseconds: 650_000_000)

        let afterStaleCompletion = await player.lifecycleDiagnostics()
        let finalSnapshot = surface.resizeDiagnosticSnapshot
        #expect(transitionCoordinator.completionInvocationCount == 1)
        #expect(transitionCoordinator.storedCompletionCount == 0)
        #expect(
            afterStaleCompletion.surfaceResizeCommands
                == reconfiguredLifecycle.surfaceResizeCommands
        )
        #expect(afterStaleCompletion.handlesCreated == reconfiguredLifecycle.handlesCreated)
        #expect(
            afterStaleCompletion.handlesDestroyed
                == reconfiguredLifecycle.handlesDestroyed
        )
        #expect(finalSnapshot.surfaceGeneration == reconfiguredGeneration)
        #expect(finalSnapshot.committedDrawableSize == expectedSize)
        #expect(finalSnapshot.pendingDrawableSize == nil)
        #expect(!finalSnapshot.hasAnimatedFallback)
        #expect(player.lastError == nil)
    }
    #endif

    private func attach(
        _ surface: MPVPlatformVideoPlayer,
        to viewController: TransitionHostingViewController,
        in window: UIWindow
    ) {
        viewController.view.frame = window.bounds
        surface.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        viewController.view.addSubview(surface)
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        surface.setNeedsLayout()
        surface.layoutIfNeeded()
        surface.updateRenderingConfiguration()
    }

    private func detach(
        _ surface: MPVPlatformVideoPlayer,
        from viewController: TransitionHostingViewController,
        in window: UIWindow
    ) {
        viewController.suppliedTransitionCoordinator = nil
        surface.detach()
        surface.removeFromSuperview()
        window.rootViewController = nil
        window.isHidden = true
    }

    private func resize(_ surface: MPVPlatformVideoPlayer, to size: CGSize) {
        surface.frame = CGRect(origin: .zero, size: size)
        surface.setNeedsLayout()
        surface.layoutIfNeeded()
    }

    private func drawableSize(of surface: MPVPlatformVideoPlayer) -> CGSize {
        MPVRenderSurfaceConfiguration.drawableSize(
            for: surface.bounds.size,
            scale: surface.metalLayer.contentsScale
        )
    }

    private func waitForLifecycle(
        _ player: MPVPlayer,
        satisfying predicate: (MPVEngineLifecycleDiagnostics) -> Bool
    ) async -> MPVEngineLifecycleDiagnostics {
        for _ in 0 ..< 150 {
            let lifecycle = await player.lifecycleDiagnostics()
            if predicate(lifecycle) {
                return lifecycle
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        return await player.lifecycleDiagnostics()
    }

    private func waitForPausedSurfaceToSettle(
        _ player: MPVPlayer,
        surface: MPVPlatformVideoPlayer
    ) async -> Bool {
        var previousLifecycle: MPVEngineLifecycleDiagnostics?
        var stableSamples = 0
        for _ in 0 ..< 150 {
            let lifecycle = await player.lifecycleDiagnostics()
            let snapshot = surface.resizeDiagnosticSnapshot
            let isSettled = player.state == .paused && !player.bufferStatus.isBuffering
                && snapshot.inFlight == nil && snapshot.pendingDrawableSize == nil
                && !snapshot.hasScheduledCommit && !snapshot.hasAnimatedFallback
                && !snapshot.hasContinuousFinalFallback && !snapshot.finalCommitRequired
            stableSamples = isSettled && lifecycle == previousLifecycle ? stableSamples + 1 : 0
            // Span the 120 ms trailing-resize window and queued observation work.
            if stableSamples >= 10 {
                return true
            }
            previousLifecycle = lifecycle
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    private func waitForResizeDiagnostic(
        _ surface: MPVPlatformVideoPlayer,
        satisfying predicate: (
            MPVRenderSurfaceResizeCoordinator.DiagnosticSnapshot
        ) -> Bool
    ) async -> MPVRenderSurfaceResizeCoordinator.DiagnosticSnapshot {
        for _ in 0 ..< 150 {
            let snapshot = surface.resizeDiagnosticSnapshot
            if predicate(snapshot) {
                return snapshot
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        return surface.resizeDiagnosticSnapshot
    }

    private func waitForPlayer(
        _ player: MPVPlayer,
        satisfying predicate: (MPVPlayer) -> Bool
    ) async -> Bool {
        for _ in 0 ..< 150 {
            if predicate(player) {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate(player)
    }

    private func waitForRenderOutputSize(
        _ expected: MPVRenderOutputSize,
        from player: MPVPlayer
    ) async -> MPVRenderOutputSize? {
        for _ in 0 ..< 150 {
            let outputSize = await player.renderOutputSize()
            if outputSize == expected {
                return outputSize
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await player.renderOutputSize()
    }

    private func waitForDrawableSize(
        _ expected: CGSize,
        in layer: CAMetalLayer
    ) async -> CGSize {
        for _ in 0 ..< 150 {
            if layer.drawableSize == expected {
                return layer.drawableSize
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return layer.drawableSize
    }
}

@MainActor
private final class TransitionHostingViewController: UIViewController {
    var suppliedTransitionCoordinator:
        (any UIViewControllerTransitionCoordinator)?

    override var transitionCoordinator:
        (any UIViewControllerTransitionCoordinator)?
    {
        suppliedTransitionCoordinator
    }
}

@MainActor
private final class TestTransitionCoordinator: NSObject,
    UIViewControllerTransitionCoordinator
{
    typealias TransitionHandler =
        (any UIViewControllerTransitionCoordinatorContext) -> Void

    let acceptsAnimationRegistration: Bool
    private(set) var animationRegistrationCount = 0
    private(set) var completionInvocationCount = 0
    private var storedCompletion: TransitionHandler?

    init(acceptsAnimationRegistration: Bool) {
        self.acceptsAnimationRegistration = acceptsAnimationRegistration
        super.init()
    }

    var storedCompletionCount: Int {
        storedCompletion == nil ? 0 : 1
    }

    func completeTransition() {
        guard let completion = storedCompletion else { return }
        storedCompletion = nil
        completionInvocationCount += 1
        completion(self)
    }

    var isAnimated: Bool {
        true
    }

    var presentationStyle: UIModalPresentationStyle {
        .none
    }

    var initiallyInteractive: Bool {
        false
    }

    var isInterruptible: Bool {
        false
    }

    var isInteractive: Bool {
        false
    }

    var isCancelled: Bool {
        false
    }

    var transitionDuration: TimeInterval {
        0.6
    }

    var percentComplete: CGFloat {
        0
    }

    var completionVelocity: CGFloat {
        1
    }

    var completionCurve: UIView.AnimationCurve {
        .linear
    }

    let containerView = UIView()
    var targetTransform: CGAffineTransform {
        .identity
    }

    func viewController(
        forKey _: UITransitionContextViewControllerKey
    ) -> UIViewController? {
        nil
    }

    func view(forKey _: UITransitionContextViewKey) -> UIView? {
        nil
    }

    func animate(
        alongsideTransition animation: TransitionHandler?,
        completion: TransitionHandler?
    ) -> Bool {
        animationRegistrationCount += 1
        guard acceptsAnimationRegistration else { return false }
        animation?(self)
        storedCompletion = completion
        return true
    }

    func animateAlongsideTransition(
        in _: UIView?,
        animation: TransitionHandler?,
        completion: TransitionHandler?
    ) -> Bool {
        animate(
            alongsideTransition: animation,
            completion: completion
        )
    }

    func notifyWhenInteractionEnds(
        _ handler: @escaping TransitionHandler
    ) {
        handler(self)
    }

    func notifyWhenInteractionChanges(
        _ handler: @escaping TransitionHandler
    ) {
        handler(self)
    }
}
#endif
