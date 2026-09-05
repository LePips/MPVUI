import MPVUI
import SwiftUI

@MainActor
public struct ContentView: View {
    @Environment(\.scenePhase)
    private var scenePhase
    @State
    private var player: MPVPlayer
    @State
    private var audioSessionError: String?
    @State
    private var lastSettledPlaybackWasPlaying = false
    @State
    private var resumesPlaybackAfterAudioSessionActivation = false

    public var body: some View {
        PlayerView(player: player)
            .task(id: scenePhase) {
                await updateAudioSession(for: scenePhase)
            }
            .onChange(of: player.state) { _, state in
                switch state {
                case .playing, .buffering:
                    lastSettledPlaybackWasPlaying = true
                case .idle, .ready, .paused, .ended, .stopped, .failed:
                    lastSettledPlaybackWasPlaying = false
                case .loading, .seeking:
                    break
                }
            }
            .alert(
                "Audio Session Error",
                isPresented: Binding(
                    get: { audioSessionError != nil },
                    set: { isPresented in
                        if !isPresented {
                            audioSessionError = nil
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {
                    audioSessionError = nil
                }
                .accessibilityIdentifier("audioSessionErrorDismissButton")
            } message: {
                Text(audioSessionError ?? "The playback audio session could not be configured.")
            }
    }

    public init() {
        let configuration = MPVPlayerConfiguration(
            autoPlay: true,
            hardwareDecoding: .automatic,
            hdrPolicy: .automatic,
            logLevel: .info,
            additionalOptions: [
                "target-contrast": "inf",
            ]
        )
        _player = State(initialValue: MPVPlayer(configuration: configuration))
    }

    private func updateAudioSession(for phase: ScenePhase) async {
        switch phase {
        case .active:
            audioSessionError = ExampleAudioSession.activate()
            #if os(iOS) || os(tvOS)
            if audioSessionError == nil, resumesPlaybackAfterAudioSessionActivation {
                resumesPlaybackAfterAudioSessionActivation = false
                player.play()
            }
            #endif
        case .background:
            #if os(iOS) || os(tvOS)
            let shouldResume: Bool = switch player.state {
            case .playing, .buffering:
                true
            case .loading:
                player.configuration.autoPlay
            case .seeking:
                lastSettledPlaybackWasPlaying
            default:
                false
            }

            if shouldResume {
                resumesPlaybackAfterAudioSessionActivation = true
                player.pause()
                guard await waitForPlaybackToPause() else { return }
            }
            #endif
            guard !Task.isCancelled else { return }
            audioSessionError = ExampleAudioSession.deactivate()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func waitForPlaybackToPause() async -> Bool {
        for _ in 0 ..< 40 {
            if playbackIsSafelySuspended {
                // Let libmpv's audio output observe the pause before the host
                // deactivates the audio session underneath it.
                try? await Task.sleep(for: .milliseconds(25))
                return !Task.isCancelled
            }

            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return false
            }
        }

        return false
    }

    private var playbackIsSafelySuspended: Bool {
        switch player.state {
        case .idle, .ready, .paused, .ended, .stopped, .failed:
            true
        case .loading, .playing, .buffering, .seeking:
            false
        }
    }
}
