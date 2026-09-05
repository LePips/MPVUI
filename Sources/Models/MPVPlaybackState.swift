/// The high-level lifecycle state of an mpv player.
public enum MPVPlaybackState: Equatable, Sendable {
    /// No media has been loaded.
    case idle

    /// A media source is being opened.
    case loading

    /// Media is loaded and can begin playback.
    case ready

    /// Playback is advancing normally.
    case playing

    /// Playback is intentionally paused.
    case paused

    /// Playback is waiting for enough media data.
    case buffering

    /// The player is applying a seek operation.
    case seeking

    /// Playback reached the end of the media.
    case ended

    /// Playback was explicitly stopped.
    case stopped

    /// Playback failed and cannot continue without another operation.
    case failed(MPVPlayerError)

    /// Whether media is currently advancing.
    public var isPlaying: Bool {
        self == .playing
    }

    /// Whether the state represents a short-lived transition.
    public var isTransient: Bool {
        switch self {
        case .loading, .buffering, .seeking:
            true
        default:
            false
        }
    }

    /// Whether the current playback attempt has finished.
    public var isTerminal: Bool {
        switch self {
        case .ended, .stopped, .failed:
            true
        default:
            false
        }
    }

    /// The associated player error when the state is ``failed(_:)``.
    public var error: MPVPlayerError? {
        guard case let .failed(error) = self else { return nil }
        return error
    }
}
