import Dispatch
@testable import MPVUI
import Testing

#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

private final class SurfaceProbe {
    var isAttachedToWindow = true
    var activationCount = 0
}

@Suite(.serialized)
struct MPVPlayerSurfaceTests {
    @MainActor
    @Test
    func `surface has the exact platform representable view type`() {
        assertPlatformRepresentableSurfaceType(MPVPlayerSurface.self)
    }

    @MainActor
    @Test
    func `shared helper creates and updates the platform surface`() {
        let player = MPVPlayer()
        let representable = MPVPlayerSurface(player: player)
        let surface = representable.makePlatformView()
        defer { dismantleRepresentableSurface(surface) }

        let platformView: PlatformView = surface
        #expect(platformView === surface)
        #expect(surface.player === player)

        #expect(
            surface.subviews.count {
                $0 is MPVPlayerSurfaceLifecycleObserver
            } == 1
        )

        representable.updatePlatformView(surface)

        #expect(!surface.isActiveRenderingSurface)
        #expect(
            surface.subviews.count {
                $0 is MPVPlayerSurfaceLifecycleObserver
            } == 1
        )
    }

    @MainActor
    @Test
    func `dismantled helper surface and lifecycle observer deallocate`() {
        let player = MPVPlayer()
        let representable = MPVPlayerSurface(player: player)
        weak var releasedSurface: MPVPlatformVideoPlayer?
        weak var releasedObserver: MPVPlayerSurfaceLifecycleObserver?

        autoreleasepool {
            let surface = representable.makePlatformView()
            releasedSurface = surface
            releasedObserver =
                surface.subviews.first {
                    $0 is MPVPlayerSurfaceLifecycleObserver
                } as? MPVPlayerSurfaceLifecycleObserver

            dismantleRepresentableSurface(surface)
        }

        #expect(releasedSurface == nil)
        #expect(releasedObserver == nil)
        #expect(!player.hasActiveRenderSurface)
    }

    @MainActor
    @Test
    func `registry schedules restoration of previous attached surface`() async {
        let player = MPVPlayer()
        let registry = MPVSwiftUISurfaceRegistry<SurfaceProbe>(
            isAttachedToWindow: { $0.isAttachedToWindow },
            activate: { $0.activationCount += 1 }
        )
        let firstSurface = SurfaceProbe()
        let supersedingSurface = SurfaceProbe()

        registry.register(firstSurface, for: player)
        registry.register(supersedingSurface, for: player)
        registry.surfaceDidMoveToWindow(
            firstSurface,
            player: player,
            isInWindow: true,
            shouldRestorePreviousSurface: false
        )
        registry.surfaceDidMoveToWindow(
            supersedingSurface,
            player: player,
            isInWindow: true,
            shouldRestorePreviousSurface: false
        )

        supersedingSurface.isAttachedToWindow = false
        registry.surfaceDidMoveToWindow(
            supersedingSurface,
            player: player,
            isInWindow: false,
            shouldRestorePreviousSurface: true
        )
        await waitForNextMainQueueTurn()

        #expect(firstSurface.activationCount == 1)
        #expect(supersedingSurface.activationCount == 0)
    }

    @MainActor
    @Test
    func `dismantling superseding surface reattaches previous live surface`() async {
        let player = MPVPlayer(
            configuration: .init(autoPlay: false, hdrPolicy: .disabled)
        )
        let firstRepresentable = MPVPlayerSurface(player: player)
        let secondRepresentable = MPVPlayerSurface(player: player)
        let firstSurface = firstRepresentable.makePlatformView()
        let secondSurface = secondRepresentable.makePlatformView()
        let firstLayer = firstSurface.metalLayer
        let firstWindow = makePlatformWindow()
        let secondWindow = makePlatformWindow()
        var firstWasDismantled = false
        var secondWasDismantled = false

        defer {
            if !secondWasDismantled {
                dismantleRepresentableSurface(secondSurface)
            }
            detachPlatformWindow(secondWindow)
            if !firstWasDismantled {
                dismantleRepresentableSurface(firstSurface)
            }
            detachPlatformWindow(firstWindow)
        }

        attach(firstSurface, to: firstWindow)
        firstRepresentable.updatePlatformView(firstSurface)
        let firstAttachment = await waitForLifecycle(player) {
            $0.handlesCreated >= 1
        }
        let firstGeneration = firstSurface.resizeDiagnosticSnapshot
            .surfaceGeneration

        #expect(firstSurface.isActiveRenderingSurface)
        #expect(player.hasActiveRenderSurface)
        #expect(firstAttachment.handlesCreated >= 1)
        #expect(firstAttachment.handlesDestroyed == 0)

        attach(secondSurface, to: secondWindow)
        secondRepresentable.updatePlatformView(secondSurface)
        let supersedingAttachment = await waitForLifecycle(player) {
            $0.handlesCreated >= firstAttachment.handlesCreated + 1
                && $0.handlesDestroyed >= firstAttachment.handlesDestroyed + 1
        }

        #expect(!firstSurface.isActiveRenderingSurface)
        #expect(secondSurface.isActiveRenderingSurface)
        #expect(
            supersedingAttachment.handlesCreated
                == firstAttachment.handlesCreated + 1
        )
        #expect(
            supersedingAttachment.handlesDestroyed
                == firstAttachment.handlesDestroyed + 1
        )

        dismantleRepresentableSurface(secondSurface)
        secondWasDismantled = true
        detachPlatformWindow(secondWindow)

        let restoredAttachment = await waitForLifecycle(player) {
            firstSurface.isActiveRenderingSurface
                && $0.handlesCreated >= supersedingAttachment.handlesCreated + 1
                && $0.handlesDestroyed >= supersedingAttachment.handlesDestroyed + 1
        }

        #expect(firstSurface.isActiveRenderingSurface)
        #expect(!secondSurface.isActiveRenderingSurface)
        #expect(firstSurface.window === firstWindow)
        #expect(secondSurface.window == nil)
        #expect(firstSurface.metalLayer === firstLayer)
        #expect(
            firstSurface.resizeDiagnosticSnapshot.surfaceGeneration
                > firstGeneration
        )
        #expect(
            restoredAttachment.handlesCreated
                == supersedingAttachment.handlesCreated + 1
        )
        #expect(
            restoredAttachment.handlesDestroyed
                == supersedingAttachment.handlesDestroyed + 1
        )
        #expect(player.lastError == nil)

        dismantleRepresentableSurface(firstSurface)
        firstWasDismantled = true
        detachPlatformWindow(firstWindow)
    }

    @MainActor
    @Test
    func `removing active superseding surface from its window restores previous live surface`()
        async
    {
        let player = MPVPlayer(
            configuration: .init(autoPlay: false, hdrPolicy: .disabled)
        )
        let firstRepresentable = MPVPlayerSurface(player: player)
        let secondRepresentable = MPVPlayerSurface(player: player)
        let firstSurface = firstRepresentable.makePlatformView()
        let secondSurface = secondRepresentable.makePlatformView()
        let firstLayer = firstSurface.metalLayer
        let secondLayer = secondSurface.metalLayer
        let firstWindow = makePlatformWindow()
        let secondWindow = makePlatformWindow()

        defer {
            dismantleRepresentableSurface(secondSurface)
            detachPlatformWindow(secondWindow)
            dismantleRepresentableSurface(firstSurface)
            detachPlatformWindow(firstWindow)
        }

        let lifecycleBeforeAttachment = await player.lifecycleDiagnostics()
        attach(firstSurface, to: firstWindow)
        firstRepresentable.updatePlatformView(firstSurface)
        let firstAttachment = await waitForLifecycle(player) {
            $0.handlesCreated >= lifecycleBeforeAttachment.handlesCreated + 1
        }

        #expect(firstSurface.isActiveRenderingSurface)
        #expect(firstAttachment.handlesCreated == lifecycleBeforeAttachment.handlesCreated + 1)
        #expect(firstAttachment.handlesDestroyed == lifecycleBeforeAttachment.handlesDestroyed)

        attach(secondSurface, to: secondWindow)
        secondRepresentable.updatePlatformView(secondSurface)
        let supersedingAttachment = await waitForLifecycle(player) {
            $0.handlesCreated >= firstAttachment.handlesCreated + 1
                && $0.handlesDestroyed >= firstAttachment.handlesDestroyed + 1
        }

        #expect(!firstSurface.isActiveRenderingSurface)
        #expect(secondSurface.isActiveRenderingSurface)
        #expect(
            supersedingAttachment.handlesCreated
                == firstAttachment.handlesCreated + 1
        )
        #expect(
            supersedingAttachment.handlesDestroyed
                == firstAttachment.handlesDestroyed + 1
        )

        removeSurfaceFromPlatformWindow(secondSurface, in: secondWindow)

        let restoredAttachment = await waitForLifecycle(player) {
            firstSurface.isActiveRenderingSurface
                && $0.handlesCreated >= supersedingAttachment.handlesCreated + 1
                && $0.handlesDestroyed >= supersedingAttachment.handlesDestroyed + 1
        }

        #expect(firstSurface.isActiveRenderingSurface)
        #expect(!secondSurface.isActiveRenderingSurface)
        #expect(firstSurface.window === firstWindow)
        #expect(secondSurface.window == nil)
        #expect(firstSurface.metalLayer === firstLayer)
        #expect(secondSurface.metalLayer === secondLayer)
        #expect(
            restoredAttachment.handlesCreated
                == supersedingAttachment.handlesCreated + 1
        )
        #expect(
            restoredAttachment.handlesDestroyed
                == supersedingAttachment.handlesDestroyed + 1
        )
        #expect(player.lastError == nil)
    }

    @MainActor
    @Test
    func `zero-sized superseder retires old target before restoring resized surface`() async {
        let player = MPVPlayer(
            configuration: .init(autoPlay: false, hdrPolicy: .disabled)
        )
        let firstRepresentable = MPVPlayerSurface(player: player)
        let secondRepresentable = MPVPlayerSurface(player: player)
        let firstSurface = firstRepresentable.makePlatformView()
        let secondSurface = secondRepresentable.makePlatformView()
        let firstLayer = firstSurface.metalLayer
        let firstWindow = makePlatformWindow()
        let secondWindow = makePlatformWindow()

        defer {
            dismantleRepresentableSurface(secondSurface)
            detachPlatformWindow(secondWindow)
            dismantleRepresentableSurface(firstSurface)
            detachPlatformWindow(firstWindow)
        }

        let lifecycleBeforeAttachment = await player.lifecycleDiagnostics()
        attach(firstSurface, to: firstWindow)
        firstRepresentable.updatePlatformView(firstSurface)
        let firstAttachment = await waitForLifecycle(player) {
            $0.handlesCreated >= lifecycleBeforeAttachment.handlesCreated + 1
        }
        let initiallyCommittedSize = firstSurface.resizeDiagnosticSnapshot
            .committedDrawableSize

        #expect(firstSurface.isActiveRenderingSurface)
        #expect(firstAttachment.handlesCreated == lifecycleBeforeAttachment.handlesCreated + 1)
        #expect(firstAttachment.handlesDestroyed == lifecycleBeforeAttachment.handlesDestroyed)

        attachZeroSized(secondSurface, to: secondWindow)
        secondRepresentable.updatePlatformView(secondSurface)

        // The token handoff is synchronous: the first handle is gone even
        // though the zero-sized owner cannot attach a replacement target.
        let zeroSizedOwnership = await player.lifecycleDiagnostics()
        #expect(!firstSurface.isActiveRenderingSurface)
        #expect(secondSurface.isActiveRenderingSurface)
        #expect(secondSurface.resizeDiagnosticSnapshot.activeLayerAddress == nil)
        #expect(
            zeroSizedOwnership.handlesCreated
                == firstAttachment.handlesCreated
        )
        #expect(
            zeroSizedOwnership.handlesDestroyed
                == firstAttachment.handlesDestroyed + 1
        )
        #expect(zeroSizedOwnership.loadCommands == firstAttachment.loadCommands)

        let restoredBoundsSize = CGSize(width: 480, height: 270)
        resizeSurface(firstSurface, to: restoredBoundsSize)
        let retainedInactiveDrawableSize = firstLayer.drawableSize
        let expectedRestoredDrawableSize =
            MPVRenderSurfaceConfiguration.drawableSize(
                for: restoredBoundsSize,
                scale: firstLayer.contentsScale
            )

        #expect(firstSurface.bounds.size == restoredBoundsSize)
        #expect(retainedInactiveDrawableSize == initiallyCommittedSize)

        removeSurfaceFromPlatformWindow(secondSurface, in: secondWindow)
        let restoredAttachment = await waitForLifecycle(player) {
            firstSurface.isActiveRenderingSurface
                && $0.handlesCreated >= firstAttachment.handlesCreated + 1
        }

        #expect(firstSurface.isActiveRenderingSurface)
        #expect(!secondSurface.isActiveRenderingSurface)
        #expect(firstSurface.metalLayer === firstLayer)
        #expect(firstLayer.drawableSize == expectedRestoredDrawableSize)
        #expect(
            firstSurface.resizeDiagnosticSnapshot.committedDrawableSize
                == expectedRestoredDrawableSize
        )
        #expect(
            restoredAttachment.handlesCreated
                == firstAttachment.handlesCreated + 1
        )
        #expect(
            restoredAttachment.handlesDestroyed
                == firstAttachment.handlesDestroyed + 1
        )
        #expect(restoredAttachment.loadCommands == firstAttachment.loadCommands)
        #expect(player.state == .idle)
        #expect(player.lastError == nil)
    }

    @MainActor
    @Test
    func `window removal and readdition reactivate the same surface and layer once`() async {
        let player = MPVPlayer(
            configuration: .init(autoPlay: false, hdrPolicy: .disabled)
        )
        let representable = MPVPlayerSurface(player: player)
        let surface = representable.makePlatformView()
        let layer = surface.metalLayer
        let window = makePlatformWindow()

        defer {
            dismantleRepresentableSurface(surface)
            detachPlatformWindow(window)
        }

        let lifecycleBeforeAttachment = await player.lifecycleDiagnostics()
        attach(surface, to: window)
        representable.updatePlatformView(surface)
        let firstAttachment = await waitForLifecycle(player) {
            $0.handlesCreated >= lifecycleBeforeAttachment.handlesCreated + 1
        }
        let firstGeneration = surface.resizeDiagnosticSnapshot.surfaceGeneration

        #expect(surface.isActiveRenderingSurface)
        #expect(surface.window === window)
        #expect(firstAttachment.handlesCreated == lifecycleBeforeAttachment.handlesCreated + 1)
        #expect(firstAttachment.handlesDestroyed == lifecycleBeforeAttachment.handlesDestroyed)

        removeSurfaceFromPlatformWindow(surface, in: window)
        await waitForNextMainQueueTurn()
        let detached = await waitForLifecycle(player) {
            !player.hasActiveRenderSurface
                && $0.handlesDestroyed >= firstAttachment.handlesDestroyed + 1
        }

        #expect(!surface.isActiveRenderingSurface)
        #expect(surface.window == nil)
        #expect(surface.metalLayer === layer)
        #expect(detached.handlesCreated == firstAttachment.handlesCreated)
        #expect(detached.handlesDestroyed == firstAttachment.handlesDestroyed + 1)

        attach(surface, to: window)
        representable.updatePlatformView(surface)
        let reattachment = await waitForLifecycle(player) {
            surface.isActiveRenderingSurface
                && $0.handlesCreated >= detached.handlesCreated + 1
        }

        #expect(surface.isActiveRenderingSurface)
        #expect(surface.window === window)
        #expect(surface.metalLayer === layer)
        #expect(
            surface.resizeDiagnosticSnapshot.surfaceGeneration
                > firstGeneration
        )
        #expect(reattachment.handlesCreated == detached.handlesCreated + 1)
        #expect(reattachment.handlesDestroyed == detached.handlesDestroyed)
        #expect(player.lastError == nil)
    }

    @MainActor
    @Test
    func `dismantling inactive surface does not disturb current owner`() async {
        let player = MPVPlayer(
            configuration: .init(autoPlay: false, hdrPolicy: .disabled)
        )
        let firstRepresentable = MPVPlayerSurface(player: player)
        let secondRepresentable = MPVPlayerSurface(player: player)
        let firstSurface = firstRepresentable.makePlatformView()
        let secondSurface = secondRepresentable.makePlatformView()
        let secondLayer = secondSurface.metalLayer
        let firstWindow = makePlatformWindow()
        let secondWindow = makePlatformWindow()
        var firstWasDismantled = false

        defer {
            if !firstWasDismantled {
                dismantleRepresentableSurface(firstSurface)
            }
            detachPlatformWindow(firstWindow)
            dismantleRepresentableSurface(secondSurface)
            detachPlatformWindow(secondWindow)
        }

        attach(firstSurface, to: firstWindow)
        firstRepresentable.updatePlatformView(firstSurface)
        let firstAttachment = await waitForLifecycle(player) {
            $0.handlesCreated >= 1
        }

        attach(secondSurface, to: secondWindow)
        secondRepresentable.updatePlatformView(secondSurface)
        let currentAttachment = await waitForLifecycle(player) {
            $0.handlesCreated >= firstAttachment.handlesCreated + 1
                && $0.handlesDestroyed >= firstAttachment.handlesDestroyed + 1
        }

        #expect(!firstSurface.isActiveRenderingSurface)
        #expect(secondSurface.isActiveRenderingSurface)

        dismantleRepresentableSurface(firstSurface)
        firstWasDismantled = true
        removeSurfaceFromPlatformWindow(firstSurface, in: firstWindow)
        await waitForNextMainQueueTurn()

        // A lifecycle snapshot is serialized behind the inactive surface's
        // conditional detach, so exact equality proves it did not tear down
        // and recreate the current owner's native handle.
        let afterInactiveDismantle = await player.lifecycleDiagnostics()

        #expect(!firstSurface.isActiveRenderingSurface)
        #expect(secondSurface.isActiveRenderingSurface)
        #expect(secondSurface.window === secondWindow)
        #expect(secondSurface.metalLayer === secondLayer)
        #expect(
            afterInactiveDismantle.handlesCreated
                == currentAttachment.handlesCreated
        )
        #expect(
            afterInactiveDismantle.handlesDestroyed
                == currentAttachment.handlesDestroyed
        )
        #expect(player.lastError == nil)
    }

    @MainActor
    private func waitForNextMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    @MainActor
    private func waitForLifecycle(
        _ player: MPVPlayer,
        satisfying predicate: (MPVEngineLifecycleDiagnostics) -> Bool
    ) async -> MPVEngineLifecycleDiagnostics {
        for _ in 0 ..< 100 {
            let lifecycle = await player.lifecycleDiagnostics()
            if predicate(lifecycle) {
                return lifecycle
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        return await player.lifecycleDiagnostics()
    }
}

#if os(macOS) && !targetEnvironment(macCatalyst)
@MainActor
private func assertPlatformRepresentableSurfaceType<Representable: PlatformViewRepresentable>(
    _: Representable.Type
) where Representable.NSViewType == MPVPlatformVideoPlayer {}
#elseif canImport(UIKit)
@MainActor
private func assertPlatformRepresentableSurfaceType<Representable: PlatformViewRepresentable>(
    _: Representable.Type
) where Representable.UIViewType == MPVPlatformVideoPlayer {}
#endif

@MainActor
private func dismantleRepresentableSurface(
    _ surface: MPVPlatformVideoPlayer
) {
    #if os(macOS) && !targetEnvironment(macCatalyst)
    MPVPlayerSurface.dismantleNSView(surface, coordinator: ())
    #elseif canImport(UIKit)
    MPVPlayerSurface.dismantleUIView(surface, coordinator: ())
    #endif
}

@MainActor
private func makePlatformWindow() -> PlatformWindow {
    #if os(macOS) && !targetEnvironment(macCatalyst)
    let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    return window
    #elseif canImport(UIKit)
    UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
    #endif
}

@MainActor
private func attach(
    _ surface: MPVPlatformVideoPlayer,
    to window: PlatformWindow
) {
    #if os(macOS) && !targetEnvironment(macCatalyst)
    window.contentView = surface
    surface.layoutSubtreeIfNeeded()
    #elseif canImport(UIKit)
    let viewController = UIViewController()
    viewController.view.frame = window.bounds
    surface.frame = viewController.view.bounds
    surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    viewController.view.addSubview(surface)
    window.rootViewController = viewController
    window.makeKeyAndVisible()
    surface.layoutIfNeeded()
    #endif
    surface.updateRenderingConfiguration()
}

@MainActor
private func attachZeroSized(
    _ surface: MPVPlatformVideoPlayer,
    to window: PlatformWindow
) {
    #if os(macOS) && !targetEnvironment(macCatalyst)
    let container = NSView(frame: window.contentLayoutRect)
    window.contentView = container
    surface.frame = .zero
    container.addSubview(surface)
    surface.layoutSubtreeIfNeeded()
    #elseif canImport(UIKit)
    let viewController = UIViewController()
    viewController.view.frame = window.bounds
    window.rootViewController = viewController
    surface.frame = .zero
    viewController.view.addSubview(surface)
    window.makeKeyAndVisible()
    surface.layoutIfNeeded()
    #endif
    surface.updateRenderingConfiguration()
}

@MainActor
private func resizeSurface(
    _ surface: MPVPlatformVideoPlayer,
    to size: CGSize
) {
    surface.frame = CGRect(origin: .zero, size: size)
    #if os(macOS) && !targetEnvironment(macCatalyst)
    surface.layoutSubtreeIfNeeded()
    #elseif canImport(UIKit)
    surface.setNeedsLayout()
    surface.layoutIfNeeded()
    #endif
}

@MainActor
private func removeSurfaceFromPlatformWindow(
    _ surface: MPVPlatformVideoPlayer,
    in window: PlatformWindow
) {
    #if os(macOS) && !targetEnvironment(macCatalyst)
    if window.contentView === surface {
        window.contentView = nil
    } else {
        surface.removeFromSuperview()
    }
    #elseif canImport(UIKit)
    surface.removeFromSuperview()
    #endif
}

@MainActor
private func detachPlatformWindow(_ window: PlatformWindow) {
    #if os(macOS) && !targetEnvironment(macCatalyst)
    window.contentView = nil
    #elseif canImport(UIKit)
    window.rootViewController = nil
    window.isHidden = true
    #endif
}
