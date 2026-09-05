/// Tracks only SwiftUI-created surfaces so removing the current owner can hand
/// rendering back to the most recently active surface that remains on screen.
@MainActor
enum MPVPlayerSurfaceRegistry {
    static let shared = MPVSwiftUISurfaceRegistry<MPVPlatformVideoPlayer>(
        isAttachedToWindow: { $0.window != nil },
        activate: { $0.activateRenderingSurface() }
    )
}
