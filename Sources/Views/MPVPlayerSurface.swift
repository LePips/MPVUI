import Dispatch
import SwiftUI

/// Bridges MPVUI's platform renderer into the SwiftUI player hierarchy.
@MainActor
struct MPVPlayerSurface: PlatformViewRepresentable {
    let player: MPVPlayer
    var overlay: MPVVideoOverlay?
    @Environment(\.self)
    private var environment

    func makePlatformView() -> MPVPlatformVideoPlayer {
        let platformView = MPVPlatformVideoPlayer(player: player)
        updateOverlay(platformView)
        MPVPlayerSurfaceRegistry.shared.register(platformView, for: player)
        platformView.addSubview(
            MPVPlayerSurfaceLifecycleObserver(
                surface: platformView,
                player: player
            )
        )
        return platformView
    }

    func updatePlatformView(_ platformView: MPVPlatformVideoPlayer) {
        updateOverlay(platformView)
        platformView.updateRenderingConfiguration()
    }

    private func updateOverlay(_ platformView: MPVPlatformVideoPlayer) {
        platformView.setVideoOverlay(overlay.map {
            MPVVideoOverlay(
                content: AnyView($0.content.environment(\.self, environment))
            )
        })
    }

    static func dismantlePlatformView(_ platformView: MPVPlatformVideoPlayer) {
        let player = platformView.player
        let shouldRestorePreviousSurface = platformView.isActiveRenderingSurface
        MPVPlayerSurfaceRegistry.shared.unregister(platformView, for: player)
        platformView.detach()
        platformView.swiftUISourceWasDismantled()

        guard shouldRestorePreviousSurface else { return }
        DispatchQueue.main.async {
            MPVPlayerSurfaceRegistry.shared.activateMostRecentSurface(for: player)
        }
    }

    #if os(macOS) && !targetEnvironment(macCatalyst)
    func makeNSView(context _: Context) -> MPVPlatformVideoPlayer {
        makePlatformView()
    }

    func updateNSView(_ nsView: MPVPlatformVideoPlayer, context _: Context) {
        updatePlatformView(nsView)
    }

    static func dismantleNSView(_ nsView: MPVPlatformVideoPlayer, coordinator _: ()) {
        dismantlePlatformView(nsView)
    }
    #elseif canImport(UIKit)
    func makeUIView(context _: Context) -> MPVPlatformVideoPlayer {
        makePlatformView()
    }

    func updateUIView(_ uiView: MPVPlatformVideoPlayer, context _: Context) {
        updatePlatformView(uiView)
    }

    static func dismantleUIView(_ uiView: MPVPlatformVideoPlayer, coordinator _: ()) {
        dismantlePlatformView(uiView)
    }
    #endif
}
