import SwiftUI

/// A native SwiftUI video surface backed by mpv.
///
/// Supply a long-lived ``MPVPlayer`` to coordinate playback with the rest of
/// your interface. Playback controls and status presentation are the
/// responsibility of the client.
@MainActor
public struct MPVVideoPlayer: View {
    private let player: MPVPlayer

    /// Creates a player view for an existing player.
    ///
    /// - Parameter player: The persistent player rendered by this view.
    public init(player: MPVPlayer) {
        self.player = player
    }

    public var body: some View {
        MPVPlayerSurface(player: player)
            .id(ObjectIdentifier(player))
            .accessibility(hidden: true)
    }
}
