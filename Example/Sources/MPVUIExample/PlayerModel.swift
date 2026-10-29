import Foundation
import Observation
#if !os(Android)
import MPVUI
#endif
import SwiftUI

// Skip's observation registrar forwards native Swift changes into Compose.
import SkipFuse

/// Owns one player for the lifetime of the shared screen.
@MainActor
@Observable
final class PlayerModel {

    let player: MPVPlayer
    var selectedName = "Choose a video"
    var selectionError: String?
    var hasMedia = false
    var audioSessionError: String?

    @ObservationIgnored
    let media: [ExampleMedia]
    #if !os(Android)
    @ObservationIgnored
    let subtitleStream: AsyncStream<TextSubtitleSnapshot>
    #endif
    @ObservationIgnored
    private let mediaAccess = ExampleMediaAccess()
    @ObservationIgnored
    private var lastSettledPlaybackWasPlaying = false
    @ObservationIgnored
    private var resumesPlaybackAfterAudioSessionActivation = false

    var position: Double {
        player.position.seconds
    }

    var duration: Double {
        player.duration.seconds
    }

    var paused: Bool {
        player.isPaused || player.state == .ended
    }

    var seekable: Bool {
        player.isSeekable
    }

    var showsVideoSurface: Bool {
        let tracks = player.mediaInformation.tracks

        // Keep the surface while a new item discovers its tracks. Removing it
        // here would start audio first and reattach video partway through startup.
        if tracks.isEmpty, player.state == .loading {
            return true
        }

        return tracks.contains { $0.type == .video }
    }

    var error: String? {
        audioSessionError ?? player.lastError?.message
    }

    var inPictureInPicture: Bool {
        player.pictureInPicture.isActive
    }

    var canStartPictureInPicture: Bool {
        let controller = player.pictureInPicture
        return controller.isSupported && controller.isPossible && !controller.isActive && !controller.isTransitioning
    }

    var details: PlayerDetails {
        let information = player.mediaInformation

        return PlayerDetails(
            tracks: information.tracks,
            resolution: information.dimensions.map { "\($0.effectiveWidth) × \($0.effectiveHeight)" } ?? "—",
            videoCodec: information.videoCodec ?? "—",
            audioCodec: information.audioCodec ?? "—",
            decoder: player.playbackDiagnostics.decoder.selectedDecoder ?? "—"
        )
    }

    init(configuration: MPVPlayerConfiguration = ExamplePlayback.configuration, media: [ExampleMedia]? = nil) {
        player = MPVPlayer(configuration: configuration)
        self.media = media ?? ExampleMedia.bundled()
        #if !os(Android)
        // Enable interception before the initial load so native text subtitles never flash.
        player.setTextSubtitleInterceptionEnabled(true)
        subtitleStream = player.makeTextSubtitleStream()
        #endif
        #if os(iOS) || os(tvOS)
        // The host-managed session must be active before the first file opens.
        audioSessionError = ExampleAudioSession.activate()
        #endif
        if let first = self.media
            .first
        {
            load(first.url)
        }
    }

    func load(_ url: URL, name: String? = nil) {
        selectionError = nil
        hasMedia = true
        mediaAccess.access(url)
        player.load(url)
        selectedName = name ?? (url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent)
    }

    func openNetworkURL(_ input: String) {
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil
        else {
            selectionError = "Enter an HTTP or HTTPS media URL."
            return
        }

        load(url)
    }

    func clearPlayerError() {
        player.clearLastError()
    }

    func background() {
        if !player.pictureInPicture.isActive && !player.pictureInPicture.isTransitioning {
            player.pause()
        }
    }

    func playbackStateChanged() {
        switch player.state {
        case .playing, .buffering:
            lastSettledPlaybackWasPlaying = true
        case .idle, .ready, .paused, .ended, .stopped, .failed:
            lastSettledPlaybackWasPlaying = false
        case .loading, .seeking:
            break
        }
    }

    func updateScenePhase(_ phase: ScenePhase) async {
        #if os(iOS) || os(tvOS)
        switch phase {
        case .active:
            audioSessionError = ExampleAudioSession.activate()

            if audioSessionError == nil, resumesPlaybackAfterAudioSessionActivation {
                resumesPlaybackAfterAudioSessionActivation = false
                player.play()
            }

        case .background:
            #if os(iOS)
            if player.externalPlayback.isPrepared || player.externalPlayback.isPreparing {
                return
            }
            #endif
            if player.pictureInPicture.isActive || player.pictureInPicture.isTransitioning {
                return
            }

            let shouldResume: Bool = switch player.state {
            case .playing, .buffering: true
            case .loading: player.configuration.automaticallyPlays && !player.isPaused
            case .seeking: lastSettledPlaybackWasPlaying
            default: false
            }

            if shouldResume {
                resumesPlaybackAfterAudioSessionActivation = true
                player.pause()
                guard await waitForPlaybackToPause() else { return }
            }

            guard !Task.isCancelled else { return }

            audioSessionError = ExampleAudioSession.deactivate()

        case .inactive:
            break

        @unknown default:
            break
        }

        // AndroidPlayback owns Activity lifecycle and resume intent. A second
        // scene-phase pause would erase that intent before onStop observes it.
        #endif
    }

    #if os(iOS) || os(tvOS)
    private func waitForPlaybackToPause() async -> Bool {
        for _ in 0 ..< 40 {
            let safelyPaused: Bool = switch player.state {
            case .idle, .ready, .paused, .ended, .stopped, .failed: true
            case .loading, .playing, .buffering, .seeking: false
            }

            do {
                // Let libmpv's audio output observe the pause before deactivation.
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return false
            }

            if safelyPaused {
                return !Task.isCancelled
            }
        }

        return false
    }
    #endif
}

struct PlayerDetails {

    var tracks: [MPVMediaTrack] = []
    var resolution = "—"
    var videoCodec = "—"
    var audioCodec = "—"
    var decoder = "—"
}

extension MPVMediaTrack {

    var exampleTitle: String {
        let value = [title, language, codec].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " · ")
        return value.isEmpty ? "Track \(mpvID)" : value
    }
}
