#if os(iOS)
import MPVUI
import SwiftUI

/// Selects an AirPlay destination from the custom controls and prepares media after selection.
@MainActor
struct AppleAirPlayButton {

    let model: PlayerModel
}

extension AppleAirPlayButton: View {

    var body: some View {
        MPVRoutePicker(player: model.player)
            .frame(width: 46, height: 48)
            .disabled(!model.hasMedia)
            .accessibilityLabel("AirPlay")
            .accessibilityIdentifier("airPlayButton")
            .overlay(alignment: .topTrailing) {
                if model.player.externalPlayback.isPreparing {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                        .allowsHitTesting(false)
                }
            }
            .alert("AirPlay", isPresented: Binding(
                get: { model.player.externalPlayback.lastError != nil },
                set: {
                    if !$0 {
                        model.player.externalPlayback.clearLastError()
                    }
                }
            )) {
                Button("OK") { model.player.externalPlayback.clearLastError() }
            } message: {
                Text(model.player.externalPlayback.lastError?.message ?? "Unable to prepare AirPlay.")
            }
    }
}

@MainActor
struct AppleAirPlaySurface {

    let model: PlayerModel
}

extension AppleAirPlaySurface: View {

    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 20) {
                symbol(size: 64)
                message
            }

            HStack(spacing: 20) {
                symbol(size: 40)
                message
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("airPlaySurface")
    }

    private var message: some View {
        let playback = model.player.externalPlayback

        return VStack(spacing: 8) {
            Text(playback.isPreparing ? "Preparing AirPlay…" : playback.isActive ? "AirPlay" : "Connecting to AirPlay…")
                .font(.title2.weight(.semibold))

            Text(playback.isActive ? "This media is playing on your AirPlay device." : "Playback will begin on your selected device.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if playback.isPreparing {
                Button("Cancel") { playback.stop() }
                    .buttonStyle(.bordered)
                    .padding(.top, 8)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func symbol(size: CGFloat) -> some View {
        Image(systemName: "airplay.video")
            .font(.system(size: size, weight: .light))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}
#endif
