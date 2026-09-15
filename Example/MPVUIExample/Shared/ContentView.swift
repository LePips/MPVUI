import MPVUI
import SwiftUI

/// The example player screen with audio session lifecycle handling.
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

    /// The player interface and audio session error alert.
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

    /// Creates the example screen with platform-specific player defaults.
    public init() {
        var configuration = MPVPlayerConfiguration(
            autoPlay: true,
            hardwareDecoding: .automatic,
            hdrPolicy: .automatic,
            logLevel: .info,
            additionalOptions: [
                "target-contrast": "inf",
            ]
        )
        #if os(macOS)
        // The macOS library includes LuaJIT. Its bundled scripts cannot run
        // under this example's hardened runtime, and our UI supplies the controls.
        // iOS/tvOS omit Lua and reject these options during initialization.
        for option in [
            "load-scripts", "osc", "ytdl", "load-stats-overlay", "load-console",
            "load-auto-profiles", "load-select", "load-positioning", "load-commands",
            "load-context-menu",
        ] {
            configuration.additionalOptions[option] = "no"
        }
        #endif
        #if os(iOS) && !targetEnvironment(macCatalyst)
        configuration.videoOutput = .sampleBuffer
        #endif
        #if DEBUG && os(macOS)
        // Exercise the iOS rendering path in the macOS example during validation.
        if ProcessInfo.processInfo.arguments.contains("--native-video-output") {
            configuration.videoOutput = .sampleBuffer
        }
        #endif
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
            #if os(iOS)
            if player.pictureInPicture.isActive || player.pictureInPicture.isTransitioning {
                return
            }
            #endif
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
