#if os(macOS)
import AppKit
import CoreGraphics
import Metal
@testable import MPVUI
import QuartzCore
import Testing

@Suite(.serialized)
struct MPVPlatformVideoPlayerAppKitTests {
    @Test
    @MainActor
    func `surface installs shared metal layer with host configuration`() {
        let surface = MPVPlatformVideoPlayer(player: MPVPlayer())
        let _: MPVPlatformVideoPlayer = surface
        let layer = surface.metalLayer

        #expect(surface.wantsLayer)
        #expect(surface.isOpaque)
        #expect(layer.isOpaque)
        #expect(layer.delegate === surface)
        #expect(layer.framebufferOnly)
        #expect(layer.contentsGravity == .resizeAspectFill)
        #expect(!layer.presentsWithTransaction)
        #expect(layer.displaySyncEnabled)
    }

    @Test
    @MainActor
    func `metal layer applies complete SDR and HDR contracts`() throws {
        let surface = MPVPlatformVideoPlayer(player: MPVPlayer())
        let layer = surface.metalLayer

        surface.configureMetalLayer(
            usesExtendedDynamicRange: true,
            scale: 2,
            outputHeadroom: 4
        )

        #expect(layer.contentsScale == 2)
        #expect(layer.pixelFormat == .rgba16Float)
        #expect(
            try #require(layer.colorspace).name
                == CGColorSpace.extendedLinearDisplayP3
        )
        #expect(layer.edrMetadata == nil)
        #expect(layer.wantsExtendedDynamicRangeContent)

        surface.configureMetalLayer(
            usesExtendedDynamicRange: false,
            scale: 1,
            outputHeadroom: 1
        )

        #expect(layer.contentsScale == 1)
        #expect(layer.pixelFormat == .bgra8Unorm)
        #expect(try #require(layer.colorspace).name == CGColorSpace.sRGB)
        #expect(layer.edrMetadata == nil)
        #expect(!layer.wantsExtendedDynamicRangeContent)
    }

    @Test
    @MainActor
    func `patched external surface size resizes in place`() async throws {
        let player = MPVPlayer(configuration: .init(autoPlay: true, hdrPolicy: .disabled))
        let surface = MPVPlatformVideoPlayer(player: player)
        let layer = surface.metalLayer
        let token = UUID()
        let initialDrawableSize = CGSize(width: 180, height: 320)
        layer.drawableSize = initialDrawableSize
        let pointer = Unmanaged.passUnretained(layer).toOpaque()
        let layerAddress = Int64(bitPattern: UInt64(UInt(bitPattern: pointer)))

        player.activateRenderSurface(token: token)
        player.attachRenderTarget(
            token: token,
            layerAddress: layerAddress,
            layerOwner: layer,
            drawableWidth: Int(initialDrawableSize.width),
            drawableHeight: Int(initialDrawableSize.height),
            usesExtendedDynamicRange: false,
            displaySupportsExtendedDynamicRange: false,
            outputHeadroom: 1
        )
        defer {
            player.detachRenderTargetSynchronously(
                token: token,
                layerAddress: layerAddress
            )
        }

        let initialLifecycle = try await waitForLifecycle(player) {
            $0.handlesCreated == 1
        }
        #expect(player.lastError == nil)
        #expect(player.isRenderSurfaceActive(token: token))
        #expect(initialLifecycle.handlesCreated == 1)
        #expect(initialLifecycle.handlesDestroyed == 0)

        let resizedDrawableSize = CGSize(width: 320, height: 180)
        let didResize = await player.resizeRenderTargetAndWait(
            token: token,
            layerAddress: layerAddress,
            drawableWidth: Int(resizedDrawableSize.width),
            drawableHeight: Int(resizedDrawableSize.height)
        )
        #expect(didResize)

        let resizedLifecycle = try await waitForLifecycle(player) {
            $0.surfaceResizeCommands == initialLifecycle.surfaceResizeCommands + 1
        }
        #expect(player.lastError == nil)
        // With no media loaded, mpv accepts and records the trigger without
        // instantiating a Vulkan swapchain. The host must not prewrite the
        // layer; video-backed integration tests cover MoltenVK's layer write.
        #expect(layer.drawableSize == initialDrawableSize)
        #expect(resizedLifecycle.handlesCreated == initialLifecycle.handlesCreated)
        #expect(resizedLifecycle.handlesDestroyed == initialLifecycle.handlesDestroyed)
        #expect(
            resizedLifecycle.surfaceResizeCommands
                == initialLifecycle.surfaceResizeCommands + 1
        )
        #expect(resizedLifecycle.loadCommands == initialLifecycle.loadCommands)
    }

    @Test
    @MainActor
    func `backing layer replacement detaches stale target and reattaches once`() async throws {
        let player = MPVPlayer(
            configuration: .init(autoPlay: false, hdrPolicy: .disabled)
        )
        let surface = MPVPlatformVideoPlayer(player: player)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.contentView = surface
        surface.layoutSubtreeIfNeeded()
        surface.updateRenderingConfiguration()
        defer {
            surface.detach()
            window.contentView = nil
        }

        let initialLifecycle = try await waitForLifecycle(player) {
            $0.handlesCreated == 1
        }
        let initialLayer = try #require(surface.metalLayer as? MPVMetalLayer)
        let initialGeneration = surface.resizeDiagnosticSnapshot.surfaceGeneration

        let replacementLayer = MPVMetalLayer()
        surface.layer = replacementLayer
        surface.layoutSubtreeIfNeeded()
        surface.updateRenderingConfiguration()

        let replacementLifecycle = try await waitForLifecycle(player) {
            $0.handlesCreated == initialLifecycle.handlesCreated + 1
                && $0.handlesDestroyed == initialLifecycle.handlesDestroyed + 1
        }

        #expect(surface.metalLayer === replacementLayer)
        #expect(surface.metalLayer !== initialLayer)
        #expect(replacementLayer.device != nil)
        #expect(replacementLayer.framebufferOnly)
        #expect(replacementLayer.isOpaque)
        #expect(replacementLayer.contentsGravity == .resizeAspectFill)
        #expect(replacementLayer.toneMapMode == .never)
        #expect(MPVMetalLayer.isValidDrawableSize(replacementLayer.drawableSize))
        #expect(surface.isActiveRenderingSurface)
        #expect(surface.resizeDiagnosticSnapshot.surfaceGeneration > initialGeneration)
        #expect(
            replacementLifecycle.handlesCreated
                == initialLifecycle.handlesCreated + 1
        )
        #expect(
            replacementLifecycle.handlesDestroyed
                == initialLifecycle.handlesDestroyed + 1
        )
        #expect(replacementLifecycle.loadCommands == initialLifecycle.loadCommands)
        #expect(player.lastError == nil)
    }

    @Test
    @MainActor
    func `fullscreen final boundary submits once and cancels fallback`() async throws {
        let player = MPVPlayer(
            configuration: .init(autoPlay: false, hdrPolicy: .disabled)
        )
        let surface = MPVPlatformVideoPlayer(player: player)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.contentView = surface
        surface.layoutSubtreeIfNeeded()
        surface.updateRenderingConfiguration()
        defer {
            surface.detach()
            window.contentView = nil
        }

        let attachedLifecycle = try await waitForLifecycle(player) {
            $0.handlesCreated == 1
        }
        #expect(attachedLifecycle.handlesCreated == 1)
        let lifecycleBeforeTransition = await player.lifecycleDiagnostics()
        let committedBeforeTransition = try #require(
            surface.resizeDiagnosticSnapshot.committedDrawableSize
        )

        surface.beginAnimatedGeometryTransition()
        surface.setFrameSize(CGSize(width: 800, height: 450))
        surface.layoutSubtreeIfNeeded()

        let expectedDrawableSize = MPVRenderSurfaceConfiguration.drawableSize(
            for: surface.bounds.size,
            scale: surface.metalLayer.contentsScale
        )
        #expect(expectedDrawableSize != committedBeforeTransition)

        let transitionSnapshot = surface.resizeDiagnosticSnapshot
        #expect(transitionSnapshot.geometryChangeKind == .animatedTransition)
        #expect(transitionSnapshot.pendingDrawableSize == expectedDrawableSize)
        #expect(transitionSnapshot.committedDrawableSize == committedBeforeTransition)
        #expect(transitionSnapshot.finalCommitRequired)
        #expect(transitionSnapshot.hasAnimatedFallback)
        #expect(transitionSnapshot.inFlight == nil)

        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(
            await player.lifecycleDiagnostics().surfaceResizeCommands
                == lifecycleBeforeTransition.surfaceResizeCommands
        )

        // Broadcasting synthetic AppKit fullscreen notifications also invokes
        // private NSWindow observers without a real transition. Exercise the
        // view adapter directly so the test owns only MPVUI state.
        surface.completeAnimatedGeometryTransition()

        let lifecycleAfterCompletion = try await waitForLifecycle(player) {
            $0.surfaceResizeCommands
                == lifecycleBeforeTransition.surfaceResizeCommands + 1
        }
        #expect(
            lifecycleAfterCompletion.surfaceResizeCommands
                == lifecycleBeforeTransition.surfaceResizeCommands + 1
        )
        let completedSnapshot = try await waitForResizeDiagnostic(surface) {
            $0.committedDrawableSize == expectedDrawableSize
                && $0.inFlight == nil
        }
        #expect(completedSnapshot.committedDrawableSize == expectedDrawableSize)
        #expect(!completedSnapshot.finalCommitRequired)
        #expect(!completedSnapshot.hasAnimatedFallback)
        #expect(completedSnapshot.pendingDrawableSize == nil)
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

        try await Task.sleep(nanoseconds: 650_000_000)
        #expect(
            await player.lifecycleDiagnostics().surfaceResizeCommands
                == lifecycleAfterCompletion.surfaceResizeCommands
        )
    }

    @Test
    @MainActor
    func `missing fullscreen completion falls back then restores discrete scheduling`()
        async throws
    {
        let player = MPVPlayer(
            configuration: .init(autoPlay: false, hdrPolicy: .disabled)
        )
        let surface = MPVPlatformVideoPlayer(player: player)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.contentView = surface
        surface.layoutSubtreeIfNeeded()
        surface.updateRenderingConfiguration()
        defer {
            surface.detach()
            window.contentView = nil
        }

        let attachedLifecycle = try await waitForLifecycle(player) {
            $0.handlesCreated == 1
        }
        #expect(attachedLifecycle.handlesCreated == 1)

        let scenarios: [(animatedSize: CGSize, discreteSize: CGSize)] = [
            (
                CGSize(width: 700, height: 400),
                CGSize(width: 720, height: 405)
            ),
            (
                CGSize(width: 740, height: 416),
                CGSize(width: 760, height: 428)
            ),
        ]

        for scenario in scenarios {
            let lifecycleBeforeTransition = await player.lifecycleDiagnostics()

            surface.beginAnimatedGeometryTransition()
            surface.setFrameSize(scenario.animatedSize)
            surface.layoutSubtreeIfNeeded()

            let animatedSnapshot = surface.resizeDiagnosticSnapshot
            #expect(animatedSnapshot.geometryChangeKind == .animatedTransition)
            #expect(animatedSnapshot.hasAnimatedFallback)
            #expect(animatedSnapshot.finalCommitRequired)
            #expect(animatedSnapshot.inFlight == nil)
            #expect(
                await player.lifecycleDiagnostics().surfaceResizeCommands
                    == lifecycleBeforeTransition.surfaceResizeCommands
            )

            let animatedDrawableSize = MPVRenderSurfaceConfiguration.drawableSize(
                for: surface.bounds.size,
                scale: surface.metalLayer.contentsScale
            )
            let lifecycleAfterFallback = try await waitForLifecycle(player) {
                $0.surfaceResizeCommands
                    == lifecycleBeforeTransition.surfaceResizeCommands + 1
            }
            #expect(
                lifecycleAfterFallback.surfaceResizeCommands
                    == lifecycleBeforeTransition.surfaceResizeCommands + 1
            )
            let fallbackSnapshot = try await waitForResizeDiagnostic(surface) {
                $0.committedDrawableSize == animatedDrawableSize
                    && $0.inFlight == nil
            }
            #expect(fallbackSnapshot.geometryChangeKind == .final)
            #expect(fallbackSnapshot.committedDrawableSize == animatedDrawableSize)
            #expect(!fallbackSnapshot.finalCommitRequired)
            #expect(!fallbackSnapshot.hasAnimatedFallback)

            // The view-owned timeout is armed from the AppKit will-* adapter,
            // independently of the coordinator's final-geometry fallback.
            try await Task.sleep(nanoseconds: 100_000_000)
            surface.layer?.removeAllAnimations()
            surface.setFrameSize(scenario.discreteSize)
            surface.layoutSubtreeIfNeeded()

            let expectedDrawableSize = MPVRenderSurfaceConfiguration.drawableSize(
                for: surface.bounds.size,
                scale: surface.metalLayer.contentsScale
            )
            let discreteSnapshot = surface.resizeDiagnosticSnapshot
            #expect(discreteSnapshot.geometryChangeKind == .discrete)
            #expect(discreteSnapshot.pendingDrawableSize == expectedDrawableSize)
            #expect(!discreteSnapshot.finalCommitRequired)
            #expect(!discreteSnapshot.hasAnimatedFallback)

            let lifecycleAfterDiscrete = try await waitForLifecycle(player) {
                $0.surfaceResizeCommands
                    == lifecycleAfterFallback.surfaceResizeCommands + 1
            }
            #expect(
                lifecycleAfterDiscrete.surfaceResizeCommands
                    == lifecycleAfterFallback.surfaceResizeCommands + 1
            )
            let committedSnapshot = try await waitForResizeDiagnostic(surface) {
                $0.committedDrawableSize == expectedDrawableSize
                    && $0.inFlight == nil
            }
            #expect(committedSnapshot.geometryChangeKind == .discrete)
            #expect(committedSnapshot.committedDrawableSize == expectedDrawableSize)
            #expect(!committedSnapshot.finalCommitRequired)
            #expect(!committedSnapshot.hasAnimatedFallback)
            #expect(
                lifecycleAfterDiscrete.handlesCreated
                    == lifecycleBeforeTransition.handlesCreated
            )
            #expect(
                lifecycleAfterDiscrete.handlesDestroyed
                    == lifecycleBeforeTransition.handlesDestroyed
            )
            #expect(
                lifecycleAfterDiscrete.loadCommands
                    == lifecycleBeforeTransition.loadCommands
            )

            try await Task.sleep(nanoseconds: 650_000_000)
            #expect(
                await player.lifecycleDiagnostics().surfaceResizeCommands
                    == lifecycleAfterDiscrete.surfaceResizeCommands
            )
        }
        #expect(player.lastError == nil)
    }

    @Test
    @MainActor
    func `live resize callbacks submit one authoritative final and cancel fallback`()
        async throws
    {
        let player = MPVPlayer(
            configuration: .init(
                autoPlay: true,
                hardwareDecoding: .disabled,
                hdrPolicy: .disabled
            )
        )
        let surface = MPVPlatformVideoPlayer(player: player)
        // Engine-backed commits can take longer than the production 120 ms
        // inactivity fallback on a loaded virtualized runner. Keep this test
        // focused on the explicit AppKit end boundary; coordinator tests cover
        // fallback timing and cancellation directly.
        surface.resizeCoordinatorTimingOverrideForTesting = .init(
            continuousTrailingDelayNanoseconds: 30_000_000_000
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.contentView = surface
        surface.layoutSubtreeIfNeeded()
        surface.updateRenderingConfiguration()
        defer {
            surface.detach()
            window.contentView = nil
        }

        let attachedLifecycle = try await waitForLifecycle(player) {
            $0.handlesCreated == 1
        }
        #expect(attachedLifecycle.handlesCreated == 1)
        let mediaURL = TestPaths.baselineMedia
        try #require(FileManager.default.fileExists(atPath: mediaURL.path))
        player.load(mediaURL, autoPlay: true)
        try #require(
            try await waitForPlayer(player) {
                $0.mediaInformation.dimensions != nil && $0.state == .playing
            }
        )
        let initialDrawableSize = try #require(
            surface.resizeDiagnosticSnapshot.committedDrawableSize
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
            surface.metalLayer.drawableSize == initialDrawableSize
        )
        let lifecycleBeforeResize = await player.lifecycleDiagnostics()

        // The boundary callbacks mirror AppKit's live-resize lifecycle while
        // allowing deterministic intermediate layouts in this integration test.
        surface.viewWillStartLiveResize()
        let beganSnapshot = surface.resizeDiagnosticSnapshot
        #expect(beganSnapshot.isContinuousInteraction)
        #expect(beganSnapshot.finalCommitRequired)

        let intermediateFrameSize = CGSize(width: 760, height: 428)
        surface.setFrameSize(intermediateFrameSize)
        surface.layoutSubtreeIfNeeded()
        let intermediateDrawableSize = MPVRenderSurfaceConfiguration.drawableSize(
            for: surface.bounds.size,
            scale: surface.metalLayer.contentsScale
        )
        let intermediateOutputSize = MPVRenderOutputSize(
            width: Int(intermediateDrawableSize.width),
            height: Int(intermediateDrawableSize.height)
        )
        let lifecycleAfterIntermediate = try await waitForLifecycle(player) {
            $0.surfaceResizeCommands
                == lifecycleBeforeResize.surfaceResizeCommands + 1
        }
        try #require(
            lifecycleAfterIntermediate.surfaceResizeCommands
                == lifecycleBeforeResize.surfaceResizeCommands + 1
        )
        let interactiveSnapshot = try await waitForResizeDiagnostic(surface) {
            $0.committedDrawableSize == intermediateDrawableSize
                && $0.geometryChangeKind == .continuousInteractive
                && $0.inFlight == nil
        }
        try #require(
            interactiveSnapshot.committedDrawableSize
                == intermediateDrawableSize
        )
        try #require(
            interactiveSnapshot.geometryChangeKind == .continuousInteractive
        )
        try #require(interactiveSnapshot.inFlight == nil)
        try #require(interactiveSnapshot.finalCommitRequired)
        try #require(interactiveSnapshot.isContinuousInteraction)
        try #require(interactiveSnapshot.hasContinuousFinalFallback)
        try #require(
            await waitForRenderOutputSize(intermediateOutputSize, from: player)
                == intermediateOutputSize
        )
        try #require(
            surface.metalLayer.drawableSize == intermediateDrawableSize
        )
        let lifecycleBeforeFinalGeometry = await player.lifecycleDiagnostics()
        try #require(
            lifecycleBeforeFinalGeometry.surfaceResizeCommands
                == lifecycleAfterIntermediate.surfaceResizeCommands
        )
        let readyForFinalSnapshot = surface.resizeDiagnosticSnapshot
        try #require(
            readyForFinalSnapshot.committedDrawableSize
                == intermediateDrawableSize
        )
        try #require(
            readyForFinalSnapshot.geometryChangeKind == .continuousInteractive
        )
        try #require(readyForFinalSnapshot.inFlight == nil)
        try #require(readyForFinalSnapshot.isContinuousInteraction)
        try #require(readyForFinalSnapshot.hasContinuousFinalFallback)

        let finalFrameSize = CGSize(width: 880, height: 495)
        surface.setFrameSize(finalFrameSize)
        surface.layoutSubtreeIfNeeded()
        let finalDrawableSize = MPVRenderSurfaceConfiguration.drawableSize(
            for: surface.bounds.size,
            scale: surface.metalLayer.contentsScale
        )
        #expect(finalDrawableSize != intermediateDrawableSize)
        let queuedContinuousSnapshot = surface.resizeDiagnosticSnapshot
        #expect(
            queuedContinuousSnapshot.geometryChangeKind
                == .continuousInteractive
        )
        #expect(queuedContinuousSnapshot.finalCommitRequired)
        #expect(queuedContinuousSnapshot.isContinuousInteraction)
        #expect(queuedContinuousSnapshot.hasContinuousFinalFallback)

        surface.viewDidEndLiveResize()

        let endSnapshot = surface.resizeDiagnosticSnapshot
        try #require(endSnapshot.geometryChangeKind == .final)
        try #require(
            endSnapshot.latestRequestedDrawableSize == finalDrawableSize
        )
        try #require(!endSnapshot.isContinuousInteraction)
        try #require(!endSnapshot.hasContinuousFinalFallback)
        try #require(endSnapshot.finalCommitRequired)
        let finalIsQueued = endSnapshot.pendingDrawableSize == finalDrawableSize
        let finalIsSubmitted =
            endSnapshot.inFlight?.drawableSize
                == finalDrawableSize
                && endSnapshot.inFlight?.geometryChangeKind == .final
        try #require(finalIsQueued || finalIsSubmitted)

        let finalSnapshot = try await waitForResizeDiagnostic(surface) {
            $0.committedDrawableSize == finalDrawableSize
                && $0.geometryChangeKind == .final
                && $0.inFlight == nil
        }
        let lifecycleAfterFinal = await player.lifecycleDiagnostics()
        try #require(
            lifecycleAfterFinal.surfaceResizeCommands
                > lifecycleAfterIntermediate.surfaceResizeCommands
        )
        let resizeCommandCount =
            lifecycleAfterFinal.surfaceResizeCommands
                - lifecycleBeforeResize.surfaceResizeCommands
        #expect(resizeCommandCount >= 2)
        #expect(resizeCommandCount <= 3)
        try #require(finalSnapshot.committedDrawableSize == finalDrawableSize)
        try #require(finalSnapshot.pendingDrawableSize == nil)
        try #require(!finalSnapshot.finalCommitRequired)
        try #require(!finalSnapshot.isContinuousInteraction)
        try #require(!finalSnapshot.hasContinuousFinalFallback)
        let finalOutputSize = MPVRenderOutputSize(
            width: Int(finalDrawableSize.width),
            height: Int(finalDrawableSize.height)
        )
        try #require(
            await waitForRenderOutputSize(finalOutputSize, from: player)
                == finalOutputSize
        )
        try #require(surface.metalLayer.drawableSize == finalDrawableSize)
        #expect(
            lifecycleAfterFinal.handlesCreated
                == lifecycleBeforeResize.handlesCreated
        )
        #expect(
            lifecycleAfterFinal.handlesDestroyed
                == lifecycleBeforeResize.handlesDestroyed
        )
        #expect(
            lifecycleAfterFinal.loadCommands
                == lifecycleBeforeResize.loadCommands
        )

        // Catch any duplicate submission from the explicit AppKit boundary.
        // The coordinator unit test separately waits beyond the fallback
        // deadline to prove the explicit end cancels that task.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(
            await player.lifecycleDiagnostics().surfaceResizeCommands
                == lifecycleAfterFinal.surfaceResizeCommands
        )
        #expect(player.lastError == nil)
    }

    @Test(arguments: [
        CGSize.zero,
        CGSize(width: 1, height: 1),
    ])
    @MainActor
    func `invalid live resize end aborts continuous interaction`(
        invalidFrameSize: CGSize
    ) async throws {
        let player = MPVPlayer(
            configuration: .init(autoPlay: false, hdrPolicy: .disabled)
        )
        let surface = MPVPlatformVideoPlayer(player: player)
        surface.displayScaleOverrideForTesting = 1
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.contentView = surface
        surface.layoutSubtreeIfNeeded()
        surface.updateRenderingConfiguration()
        defer {
            surface.detach()
            window.contentView = nil
        }

        let attachedLifecycle = try await waitForLifecycle(player) {
            $0.handlesCreated == 1
        }
        try #require(attachedLifecycle.handlesCreated == 1)
        let committedBeforeResize = try #require(
            surface.resizeDiagnosticSnapshot.committedDrawableSize
        )

        surface.viewWillStartLiveResize()
        let beganSnapshot = surface.resizeDiagnosticSnapshot
        #expect(beganSnapshot.isContinuousInteraction)
        #expect(beganSnapshot.finalCommitRequired)

        surface.setFrameSize(invalidFrameSize)
        surface.viewDidEndLiveResize()

        let abortedSnapshot = surface.resizeDiagnosticSnapshot
        #expect(!abortedSnapshot.isContinuousInteraction)
        #expect(!abortedSnapshot.finalCommitRequired)
        #expect(!abortedSnapshot.hasContinuousFinalFallback)
        #expect(!abortedSnapshot.hasScheduledCommit)
        #expect(abortedSnapshot.latestRequestedDrawableSize == nil)
        #expect(abortedSnapshot.pendingDrawableSize == nil)
        #expect(abortedSnapshot.inFlight == nil)
        #expect(abortedSnapshot.committedDrawableSize == committedBeforeResize)
        #expect(abortedSnapshot.activeLayerAddress != nil)

        try await Task.sleep(nanoseconds: 200_000_000)
        let lifecycleAfterAbort = await player.lifecycleDiagnostics()
        #expect(
            lifecycleAfterAbort.surfaceResizeCommands
                == attachedLifecycle.surfaceResizeCommands
        )
        #expect(lifecycleAfterAbort.handlesCreated == attachedLifecycle.handlesCreated)
        #expect(
            lifecycleAfterAbort.handlesDestroyed
                == attachedLifecycle.handlesDestroyed
        )
        #expect(player.lastError == nil)
    }

    @Test
    @MainActor
    func `backing scale change commits exact pixel geometry in place`() async throws {
        let player = MPVPlayer(
            configuration: .init(
                autoPlay: true,
                hardwareDecoding: .disabled,
                hdrPolicy: .disabled
            )
        )
        let surface = MPVPlatformVideoPlayer(player: player)
        surface.displayScaleOverrideForTesting = 1
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.contentView = surface
        surface.layoutSubtreeIfNeeded()
        surface.updateRenderingConfiguration()
        defer {
            surface.detach()
            window.contentView = nil
        }

        try #require(
            try await waitForLifecycle(player) { $0.handlesCreated == 1 }
                .handlesCreated == 1
        )
        let mediaURL = TestPaths.baselineMedia
        try #require(FileManager.default.fileExists(atPath: mediaURL.path))
        player.load(mediaURL, autoPlay: true)
        try #require(
            try await waitForPlayer(player) {
                $0.mediaInformation.dimensions != nil && $0.state == .playing
            }
        )
        let initialDrawableSize = CGSize(width: 640, height: 360)
        let initialOutputSize = MPVRenderOutputSize(width: 640, height: 360)
        let initialSnapshot = try await waitForResizeDiagnostic(surface) {
            $0.committedDrawableSize == initialDrawableSize
                && $0.committedContentsScale == 1
                && $0.inFlight == nil
        }
        try #require(initialSnapshot.committedDrawableSize == initialDrawableSize)
        try #require(initialSnapshot.committedContentsScale == 1)
        try #require(initialSnapshot.inFlight == nil)
        try #require(
            await waitForRenderOutputSize(initialOutputSize, from: player)
                == initialOutputSize
        )
        try #require(surface.metalLayer.contentsScale == 1)
        try #require(surface.metalLayer.drawableSize == initialDrawableSize)
        let lifecycleBeforeScaleChange = await player.lifecycleDiagnostics()

        surface.displayScaleOverrideForTesting = 2
        surface.viewDidChangeBackingProperties()
        let expectedDrawableSize = CGSize(width: 1280, height: 720)
        let expectedOutputSize = MPVRenderOutputSize(width: 1280, height: 720)
        let scheduledSnapshot = surface.resizeDiagnosticSnapshot
        #expect(surface.metalLayer.contentsScale == 1)
        #expect(surface.metalLayer.drawableSize == initialDrawableSize)
        #expect(scheduledSnapshot.committedDrawableSize == initialDrawableSize)
        #expect(scheduledSnapshot.latestRequestedDrawableSize == expectedDrawableSize)
        let lifecycleAfterScaleChange = try await waitForLifecycle(player) {
            $0.surfaceResizeCommands
                == lifecycleBeforeScaleChange.surfaceResizeCommands + 1
        }
        try #require(
            lifecycleAfterScaleChange.surfaceResizeCommands
                == lifecycleBeforeScaleChange.surfaceResizeCommands + 1
        )
        let committedSnapshot = try await waitForResizeDiagnostic(surface) {
            $0.committedDrawableSize == expectedDrawableSize
                && $0.committedContentsScale == 2
                && $0.inFlight == nil
        }

        try #require(surface.metalLayer.contentsScale == 2)
        try #require(surface.metalLayer.drawableSize == expectedDrawableSize)
        try #require(committedSnapshot.geometryChangeKind == .discrete)
        try #require(committedSnapshot.committedDrawableSize == expectedDrawableSize)
        try #require(committedSnapshot.committedContentsScale == 2)
        try #require(committedSnapshot.inFlight == nil)
        try #require(committedSnapshot.pendingDrawableSize == nil)
        try #require(
            await waitForRenderOutputSize(expectedOutputSize, from: player)
                == expectedOutputSize
        )
        #expect(
            lifecycleAfterScaleChange.handlesCreated
                == lifecycleBeforeScaleChange.handlesCreated
        )
        #expect(
            lifecycleAfterScaleChange.handlesDestroyed
                == lifecycleBeforeScaleChange.handlesDestroyed
        )
        #expect(
            lifecycleAfterScaleChange.loadCommands
                == lifecycleBeforeScaleChange.loadCommands
        )
        #expect(player.state == .playing)
        #expect(player.lastError == nil)
    }

    @Test(
        .enabled(
            if: TestPaths.hasMedia("02-h264-multitrack.mkv"),
            "Requires the optional local multitrack fixture."
        )
    )
    @MainActor
    func `track selection updates reported tracks`() async throws {
        let player = MPVPlayer(
            configuration: .init(
                autoPlay: false,
                hdrPolicy: .disabled,
                logLevel: .debug
            )
        )
        let nativeSurfaceConfigurations = NativeSurfaceConfigurationLogRecorder()
        player.logHandler = { nativeSurfaceConfigurations.record($0) }
        let subtitleSnapshots = TextSubtitleSnapshotRecorder()
        let subtitleStream = player.textSubtitleStream()
        let subtitleObservation = Task { @MainActor in
            for await snapshot in subtitleStream {
                subtitleSnapshots.values.append(snapshot)
            }
        }
        defer {
            subtitleObservation.cancel()
            player.logHandler = nil
        }

        let surface = MPVPlatformVideoPlayer(player: player)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.contentView = surface
        surface.layoutSubtreeIfNeeded()
        surface.updateRenderingConfiguration()
        defer {
            surface.detach()
            window.contentView = nil
        }

        let layer = surface.metalLayer

        let mediaURL = TestPaths.media("02-h264-multitrack.mkv")
        try #require(FileManager.default.fileExists(atPath: mediaURL.path))

        player.load(mediaURL, autoPlay: true)
        let didLoadTracks = try await waitForPlayer(player) {
            $0.audioTracks.contains { $0.language == "spa" }
                && $0.subtitleTracks.contains { $0.language == "jpn" }
                && $0.subtitleTracks.contains {
                    $0.language == "eng" && $0.codec == "subrip"
                }
        }
        try #require(didLoadTracks)
        try #require(try await waitForPlayer(player) { $0.state == .playing })
        try #require(player.lastError == nil)
        try #require(layer.pixelFormat == .bgra8Unorm)
        try #require(!layer.wantsExtendedDynamicRangeContent)

        let spanishAudio = try #require(
            player.audioTracks.first { $0.language == "spa" }
        )
        player.selectTrack(spanishAudio)
        let didSelectSpanishAudio = try await waitForPlayer(player) {
            $0.audioTracks.first(where: { $0.id == spanishAudio.id })?.isSelected == true
        }
        try #require(didSelectSpanishAudio)

        let japaneseSubtitle = try #require(
            player.subtitleTracks.first { $0.language == "jpn" }
        )
        player.selectTrack(japaneseSubtitle)
        let didSelectJapaneseSubtitle = try await waitForPlayer(player) {
            $0.subtitleTracks.first(where: { $0.id == japaneseSubtitle.id })?.isSelected == true
        }
        try #require(didSelectJapaneseSubtitle)

        let englishSubtitle = try #require(
            player.subtitleTracks.first {
                $0.language == "eng" && $0.codec == "subrip"
            }
        )
        player.selectTrack(englishSubtitle)
        let didSelectEnglishSubtitle = try await waitForPlayer(player) {
            $0.subtitleTracks.first(where: { $0.id == englishSubtitle.id })?
                .isSelected == true
        }
        try #require(didSelectEnglishSubtitle)

        player.seek(to: .seconds(1))
        try #require(
            await waitForSubtitleSnapshot(
                subtitleSnapshots,
                containing: "[Embedded English]"
            )
        )
        try #require(try await waitForPlayer(player) { $0.state == .playing })

        let lifecycleBeforeResize = await player.lifecycleDiagnostics()
        window.setContentSize(CGSize(width: 800, height: 450))
        surface.layoutSubtreeIfNeeded()
        CATransaction.flush()
        let resizedDrawableSize = MPVRenderSurfaceConfiguration.drawableSize(
            for: surface.bounds.size,
            scale: layer.contentsScale
        )
        let expectedOutputSize = MPVRenderOutputSize(
            width: Int(resizedDrawableSize.width),
            height: Int(resizedDrawableSize.height)
        )
        try #require(
            await waitForRenderOutputSize(expectedOutputSize, from: player)
                == expectedOutputSize
        )
        try #require(layer.drawableSize == resizedDrawableSize)
        try #require(layer.pixelFormat == .bgra8Unorm)
        try #require(try await waitForPlayer(player) { $0.state == .playing })
        try #require(
            player.audioTracks.first(where: { $0.id == spanishAudio.id })?
                .isSelected == true
        )
        try #require(
            player.subtitleTracks.first(where: { $0.id == englishSubtitle.id })?
                .isSelected == true
        )

        // A cue change after the native resize proves the same text-subtitle
        // interception observation remains live; checking only the cached
        // pre-resize snapshot would not exercise that contract.
        player.seek(to: .seconds(5))
        try #require(
            await waitForSubtitleSnapshot(
                subtitleSnapshots,
                containing: "EN track cue 2"
            )
        )

        player.pause()
        try #require(try await waitForPlayer(player) { $0.state == .paused })

        let lifecycleAfterResize = await player.lifecycleDiagnostics()
        try #require(
            lifecycleAfterResize.surfaceResizeCommands
                > lifecycleBeforeResize.surfaceResizeCommands
        )
        try #require(
            lifecycleAfterResize.handlesCreated
                == lifecycleBeforeResize.handlesCreated
        )
        try #require(
            lifecycleAfterResize.handlesDestroyed
                == lifecycleBeforeResize.handlesDestroyed
        )
        try #require(
            lifecycleAfterResize.loadCommands == lifecycleBeforeResize.loadCommands
        )

        try #require(surface.requestAuthoritativeFinalResize())
        let lifecycleAfterForcedFinal = try await waitForLifecycle(player) {
            $0.surfaceResizeCommands
                == lifecycleAfterResize.surfaceResizeCommands + 1
        }
        try #require(
            lifecycleAfterForcedFinal.surfaceResizeCommands
                == lifecycleAfterResize.surfaceResizeCommands + 1
        )
        try #require(
            await waitForRenderOutputSize(expectedOutputSize, from: player)
                == expectedOutputSize
        )
        try #require(layer.drawableSize == resizedDrawableSize)
        try #require(
            lifecycleAfterForcedFinal.handlesCreated
                == lifecycleAfterResize.handlesCreated
        )
        try #require(
            lifecycleAfterForcedFinal.handlesDestroyed
                == lifecycleAfterResize.handlesDestroyed
        )
        try #require(
            lifecycleAfterForcedFinal.loadCommands
                == lifecycleAfterResize.loadCommands
        )
        let totalResizeCommandCount =
            lifecycleAfterForcedFinal.surfaceResizeCommands
                - lifecycleBeforeResize.surfaceResizeCommands
        try #require(totalResizeCommandCount > 0)
        try #require(totalResizeCommandCount <= 3)
        let evidenceSnapshot = surface.resizeDiagnosticSnapshot
        try #require(
            evidenceSnapshot.committedDrawableSize == resizedDrawableSize
        )
        try #require(evidenceSnapshot.inFlight == nil)
        try #require(!evidenceSnapshot.finalCommitRequired)
        let resizeLatency = try #require(
            evidenceSnapshot.resizeLatencyNanoseconds
        )
        let nativeSurfaceConfiguration = try #require(
            await waitForNativeSurfaceConfiguration(
                nativeSurfaceConfigurations
            )
        )
        try #require(
            nativeSurfaceConfiguration.contains("VK_FORMAT_B8G8R8A8_UNORM")
        )
        try #require(
            nativeSurfaceConfiguration.contains(
                "VK_COLOR_SPACE_SRGB_NONLINEAR_KHR"
            )
        )
        try #require(player.state == .paused)
        try #require(player.lastError == nil)
        print(
            "MPVUI_RESIZE_EVIDENCE scenario=macos-sdr-playing-paused-forced-final commands="
                + "\(totalResizeCommandCount) "
                + "latencyNs=\(resizeLatency) pixelFormat=\(layer.pixelFormat.rawValue) "
                + "output=\(expectedOutputSize.width)x\(expectedOutputSize.height) "
                + "nativeSurfaceConfiguration=\""
                + sanitizedEvidenceValue(nativeSurfaceConfiguration)
                + "\""
        )

        player.disableTrack(.subtitle)
        let didDisableSubtitles = try await waitForPlayer(player) {
            !$0.subtitleTracks.contains(where: \.isSelected)
        }
        #expect(didDisableSubtitles)
        #expect(player.lastError == nil)
    }

    @Test(
        .enabled(
            if: TestPaths.hasMedia("08-hevc-hdr10-4k-eac3.mp4"),
            "Requires the optional local HDR fixture."
        )
    )
    @MainActor
    func `hdr surface survives repeated window resizes`() async throws {
        let player = MPVPlayer(
            configuration: .init(
                autoPlay: true,
                hdrPolicy: .always,
                logLevel: .debug
            )
        )
        let nativeSurfaceConfigurations = NativeSurfaceConfigurationLogRecorder()
        player.logHandler = { nativeSurfaceConfigurations.record($0) }
        defer { player.logHandler = nil }
        let surface = MPVPlatformVideoPlayer(player: player)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.contentView = surface
        surface.layoutSubtreeIfNeeded()
        surface.updateRenderingConfiguration()
        defer {
            surface.detach()
            window.contentView = nil
        }

        let mediaURL = TestPaths.media("08-hevc-hdr10-4k-eac3.mp4")
        try #require(FileManager.default.fileExists(atPath: mediaURL.path))

        player.load(mediaURL, autoPlay: true)
        let didStartPlayback = try await waitForPlayer(player) {
            $0.state == .playing
        }
        try #require(didStartPlayback)
        try #require(player.lastError == nil)
        let initialMetalLayer = surface.metalLayer
        let displaySupportsHDR =
            ((window.screen ?? NSScreen.main)?
                .maximumPotentialExtendedDynamicRangeColorComponentValue
                ?? 1) > 1
        guard displaySupportsHDR else {
            print(
                "MPVUI_RESIZE_EVIDENCE scenario=macos-hdr-playing status=NOT_RUN "
                    + "reason=no-edr-display"
            )
            return
        }
        try #require(initialMetalLayer.pixelFormat == .rgba16Float)
        try #require(initialMetalLayer.wantsExtendedDynamicRangeContent)
        let positionBeforeResize = player.position
        let lifecycleBeforeResize = await player.lifecycleDiagnostics()

        for index in 0 ..< 6 {
            let contentSize =
                index.isMultiple(of: 2)
                ? CGSize(width: 1280, height: 720)
                : CGSize(width: 640, height: 360)
            window.setContentSize(contentSize)
            surface.layoutSubtreeIfNeeded()
            CATransaction.flush()
            try await Task.sleep(nanoseconds: 125_000_000)
        }

        let didResumePlayback = try await waitForPlayer(player) {
            $0.state == .playing
        }
        try #require(player.lastError == nil)
        try #require(didResumePlayback)
        try #require(surface.metalLayer === initialMetalLayer)
        try #require(surface.metalLayer.delegate === surface)
        let expectedDrawableSize = MPVRenderSurfaceConfiguration.drawableSize(
            for: surface.bounds.size,
            scale: surface.metalLayer.contentsScale
        )
        let expectedOutputSize = MPVRenderOutputSize(
            width: Int(expectedDrawableSize.width),
            height: Int(expectedDrawableSize.height)
        )
        try #require(
            await waitForRenderOutputSize(expectedOutputSize, from: player)
                == expectedOutputSize
        )
        try #require(surface.metalLayer.drawableSize == expectedDrawableSize)
        try #require(surface.metalLayer.pixelFormat == .rgba16Float)
        try #require(surface.metalLayer.wantsExtendedDynamicRangeContent)
        try #require(player.position >= positionBeforeResize)
        let lifecycleAfterResize = await player.lifecycleDiagnostics()
        try #require(
            lifecycleAfterResize.handlesCreated
                == lifecycleBeforeResize.handlesCreated
        )
        try #require(
            lifecycleAfterResize.handlesDestroyed
                == lifecycleBeforeResize.handlesDestroyed
        )
        try #require(
            lifecycleAfterResize.loadCommands == lifecycleBeforeResize.loadCommands
        )
        try #require(
            lifecycleAfterResize.loadingStateTransitions
                == lifecycleBeforeResize.loadingStateTransitions
        )
        let resizeCommandCount =
            lifecycleAfterResize.surfaceResizeCommands
                - lifecycleBeforeResize.surfaceResizeCommands
        try #require(resizeCommandCount > 0)
        try #require(resizeCommandCount <= 6)
        let evidenceSnapshot = surface.resizeDiagnosticSnapshot
        try #require(
            evidenceSnapshot.committedDrawableSize == expectedDrawableSize
        )
        try #require(evidenceSnapshot.inFlight == nil)
        let resizeLatency = try #require(
            evidenceSnapshot.resizeLatencyNanoseconds
        )
        let nativeSurfaceConfiguration = try #require(
            await waitForNativeSurfaceConfiguration(
                nativeSurfaceConfigurations
            )
        )
        try #require(
            nativeSurfaceConfiguration.contains(
                "VK_FORMAT_R16G16B16A16_SFLOAT"
            )
        )
        try #require(
            nativeSurfaceConfiguration.contains(
                "VK_COLOR_SPACE_DISPLAY_P3_LINEAR_EXT"
            )
        )
        try #require(player.state == .playing)
        try #require(player.lastError == nil)
        print(
            "MPVUI_RESIZE_EVIDENCE scenario=macos-hdr-playing commands="
                + "\(resizeCommandCount) "
                + "latencyNs=\(resizeLatency) pixelFormat=\(surface.metalLayer.pixelFormat.rawValue) "
                + "output=\(expectedOutputSize.width)x\(expectedOutputSize.height) "
                + "nativeSurfaceConfiguration=\""
                + sanitizedEvidenceValue(nativeSurfaceConfiguration)
                + "\""
        )
    }

    @MainActor
    private func waitForRenderOutputSize(
        _ expected: MPVRenderOutputSize,
        from player: MPVPlayer
    ) async -> MPVRenderOutputSize? {
        for _ in 0 ..< 100 {
            let outputSize = await player.renderOutputSize()
            if outputSize == expected {
                return outputSize
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await player.renderOutputSize()
    }

    @MainActor
    private func waitForLifecycle(
        _ player: MPVPlayer,
        satisfying predicate: (MPVEngineLifecycleDiagnostics) -> Bool
    ) async throws -> MPVEngineLifecycleDiagnostics {
        for _ in 0 ..< 100 {
            let lifecycle = await player.lifecycleDiagnostics()
            if predicate(lifecycle) {
                return lifecycle
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        return await player.lifecycleDiagnostics()
    }

    @MainActor
    private func waitForResizeDiagnostic(
        _ surface: MPVPlatformVideoPlayer,
        satisfying predicate: (
            MPVRenderSurfaceResizeCoordinator.DiagnosticSnapshot
        ) -> Bool
    ) async throws -> MPVRenderSurfaceResizeCoordinator.DiagnosticSnapshot {
        for _ in 0 ..< 100 {
            let snapshot = surface.resizeDiagnosticSnapshot
            if predicate(snapshot) {
                return snapshot
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        return surface.resizeDiagnosticSnapshot
    }

    @MainActor
    private func waitForPlayer(
        _ player: MPVPlayer,
        satisfying predicate: (MPVPlayer) -> Bool
    ) async throws -> Bool {
        for _ in 0 ..< 200 {
            if predicate(player) {
                return true
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        return predicate(player)
    }

    @MainActor
    private func waitForSubtitleSnapshot(
        _ recorder: TextSubtitleSnapshotRecorder,
        containing text: String
    ) async -> Bool {
        for _ in 0 ..< 100 {
            if recorder.values.contains(where: { $0.text.contains(text) }) {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        return recorder.values.contains(where: { $0.text.contains(text) })
    }

    @MainActor
    private func waitForNativeSurfaceConfiguration(
        _ recorder: NativeSurfaceConfigurationLogRecorder
    ) async -> String? {
        for _ in 0 ..< 100 {
            if let configuration = recorder.values.last {
                return configuration
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        return recorder.values.last
    }

    private func sanitizedEvidenceValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}

@MainActor
private final class TextSubtitleSnapshotRecorder {
    var values: [TextSubtitleSnapshot] = []
}

@MainActor
private final class NativeSurfaceConfigurationLogRecorder {
    var values: [String] = []

    func record(_ message: MPVLogMessage) {
        guard message.prefix.contains("libplacebo"),
              message.message.contains("Picked surface configuration")
        else { return }

        values.append(message.message)
    }
}

#endif
