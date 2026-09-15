import SwiftUI

/// A SwiftUI video surface for `MPVPlayer`.
///
/// Add your own playback controls. Use `videoOverlay(alignment:content:)`
/// for content that follows the video into picture in picture.
///
/// ```swift
/// struct VideoScreen: View {
///     let url: URL
///     @State private var player = MPVPlayer()
///
///     var body: some View {
///         MPVVideoPlayer(player: player)
///             .videoOverlay(alignment: .bottom) {
///                 Text("Now playing").padding()
///             }
///             .task(id: url) { player.load(url) }
///     }
/// }
/// ```
@MainActor
public struct MPVVideoPlayer: View {
    private let player: MPVPlayer
    private var overlay: MPVVideoOverlay?

    /// Displays an existing player.
    public init(player: MPVPlayer) {
        self.player = player
    }

    /// The video surface and its configured overlay.
    public var body: some View {
        MPVPlayerSurface(player: player, overlay: overlay)
            .id(ObjectIdentifier(player))
    }

    /// Places content inside the video surface, including picture in picture.
    ///
    /// macOS moves the live view into PiP. iOS rasterizes SwiftUI drawing into
    /// native frames; ImageRenderer cannot capture platform views such as web or
    /// video views. The iOS copy is noninteractive with separate local state;
    /// use a shared observable model for changing content.
    ///
    /// Supports custom subtitles from ``MPVPlayer/textSubtitleStream()`` without
    /// changing interception. Repeated calls replace the previous overlay.
    public func videoOverlay(
        alignment: Alignment = .center,
        @ViewBuilder content: () -> some View
    ) -> Self {
        var copy = self
        copy.overlay = MPVVideoOverlay(
            content: AnyView(content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment))
        )
        return copy
    }
}

@MainActor
struct MPVVideoOverlay {
    let content: AnyView
}
