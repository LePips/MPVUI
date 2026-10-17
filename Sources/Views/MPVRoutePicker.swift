import MPVCore
#if os(iOS)
import AVKit
import SwiftUI

/// An AirPlay destination picker for custom playback controls.
///
/// Prepares the current media after an AirPlay destination is selected.
/// Opening or dismissing the picker while playing locally does not prepare media.
/// Keep ``MPVVideoPlayer`` in the view hierarchy and use ``MPVPlayer`` for playback controls.
/// Selecting the local device returns playback to mpv. Preparation errors appear in
/// ``MPVExternalPlaybackController/lastError``.
@MainActor
public struct MPVRoutePicker {

    private let player: MPVPlayer

    /// Creates a destination picker for the player's current media.
    public init(player: MPVPlayer) {
        self.player = player
    }
}

extension MPVRoutePicker: View {

    /// The system AirPlay button for choosing a playback destination.
    public var body: some View {
        RoutePicker(player: player)
            .id(ObjectIdentifier(player))
    }
}

private struct RoutePicker {

    @MainActor
    final class Coordinator: NSObject {

        var player: MPVPlayer

        init(player: MPVPlayer) {
            self.player = player
        }
    }

    let player: MPVPlayer
}

extension RoutePicker.Coordinator: @preconcurrency AVRoutePickerViewDelegate {

    func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        player.externalPlayback.prepareForRouteSelection()
    }

    func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        player.externalPlayback.updateAirPlayRoute(
            isSelected: AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay },
            retry: true
        )
    }
}

extension RoutePicker: UIViewRepresentable {

    func makeCoordinator() -> Coordinator {
        Coordinator(player: player)
    }

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.tintColor = .label
        view.activeTintColor = .systemBlue
        view.delegate = context.coordinator
        player.externalPlayback.observeAirPlayRoutes()
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        context.coordinator.player = player
        view.isUserInteractionEnabled = context.environment.isEnabled
        view.alpha = context.environment.isEnabled ? 1 : 0.4
    }
}

/// Attaches the system player's video layer beneath the app's custom controls.
struct MPVExternalPlaybackSurface {

    final class VideoView: UIView {

        override class var layerClass: AnyClass {
            AVPlayerLayer.self
        }

        var playerLayer: AVPlayerLayer {
            layer as! AVPlayerLayer
        }
    }

    let player: MPVPlayer
}

extension MPVExternalPlaybackSurface: UIViewRepresentable {

    static func dismantleUIView(_ view: VideoView, coordinator: ()) {
        view.playerLayer.player = nil
    }

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        view.playerLayer.player = player.externalPlayback.systemPlayer
        return view
    }

    func updateUIView(_ view: VideoView, context: Context) {
        view.playerLayer.player = player.externalPlayback.systemPlayer
    }
}
#endif
