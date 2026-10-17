import MPVCore
#if os(iOS)
import AVKit
import SwiftUI

/// The system video interface with playback controls and AirPlay destination selection.
///
/// Await `player.externalPlayback.start()` before presenting this view.
/// Dismissing it leaves playback running. Call `player.externalPlayback.stop()` to return to mpv.
/// For packaged media, the system seek bar covers the available HLS window.
/// Use `player.seek(to:)` to seek anywhere in the original source, restarting packaging when needed.
@MainActor
public struct MPVExternalPlaybackView {

    private let player: MPVPlayer

    /// Creates a view for the player's prepared external playback session.
    public init(player: MPVPlayer) {
        self.player = player
    }
}

extension MPVExternalPlaybackView: UIViewControllerRepresentable {

    /// Detaches the interface while preserving the selected destination and playback state.
    public static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player = nil
    }

    /// Creates the standard system playback interface.
    public func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player.externalPlayback.systemPlayer
        controller.allowsPictureInPicturePlayback = false
        return controller
    }

    /// Updates the interface to use the player's external playback session.
    public func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player.externalPlayback.systemPlayer
    }
}
#endif
