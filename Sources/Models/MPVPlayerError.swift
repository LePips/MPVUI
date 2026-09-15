/// Playback and picture-in-picture failures. mpv errors retain their native code and message.
public enum MPVPlayerError: Error, Equatable, Sendable {
    /// The mpv client could not be created.
    case clientCreationFailed
    /// The mpv client is unavailable.
    case clientUnavailable
    /// mpv initialization failed with the supplied context and native error.
    case initializationFailed(context: String, code: Int32, message: String)
    /// Media loading failed with the supplied native error.
    case loadFailed(code: Int32, message: String)
    /// Playback failed with the supplied native error.
    case playbackFailed(code: Int32, message: String)

    /// A command, property update, or observation failed without ending playback.
    case commandFailed(context: String, code: Int32, message: String)
    /// The named property is managed by MPVUI and cannot be set directly.
    case reservedProperty(name: String)
    /// Subtitle selection requires a subtitle identifier from the current item.
    case invalidSubtitleTrack(MPVMediaTrackIdentifier)
    /// mpv's event queue overflowed and player state was refreshed.
    case eventQueueOverflow
    /// Picture in picture is unsupported by the platform or video output.
    case pictureInPictureUnsupported
    /// The current video is not ready for picture in picture.
    case pictureInPictureNotReady
    /// The specified picture-in-picture operation failed.
    case pictureInPictureFailed(operation: PictureInPictureOperation, message: String)
    /// The specified picture-in-picture operation timed out.
    case pictureInPictureTimedOut(operation: PictureInPictureOperation)

    /// The picture-in-picture operation that failed or timed out.
    public enum PictureInPictureOperation: Equatable, Sendable {
        /// Starting picture in picture.
        case start
        /// Closing picture in picture.
        case stop
        /// Seeking from picture in picture.
        case seek
        /// Restoring the inline playback interface.
        case restoreInterface
    }

    /// A readable description of the failure.
    public var localizedDescription: String {
        switch self {
        case .clientCreationFailed:
            "Unable to create the mpv client."
        case .clientUnavailable:
            "mpv is not available."
        case let .initializationFailed(context, _, message),
             let .commandFailed(context, _, message):
            "\(context): \(message)"
        case let .loadFailed(_, message):
            "Load media: \(message)"
        case let .playbackFailed(_, message):
            "Playback failed: \(message)"
        case let .reservedProperty(name):
            "The mpv property '\(name)' is managed by MPVUI."
        case .invalidSubtitleTrack:
            "Choose a subtitle track from the currently loaded media."
        case .eventQueueOverflow:
            "The mpv event queue overflowed; player state was refreshed."
        case .pictureInPictureUnsupported:
            "Picture in Picture requires native sample-buffer output on a supported iOS device, or the macOS PiP host."
        case .pictureInPictureNotReady:
            "Picture in Picture is not ready for the current video."
        case let .pictureInPictureFailed(_, message):
            message
        case .pictureInPictureTimedOut(operation: .start):
            "Picture in Picture did not start before the system transition timed out."
        case .pictureInPictureTimedOut(operation: .stop):
            "Picture in Picture did not finish closing before the system transition timed out."
        case .pictureInPictureTimedOut(operation: .seek):
            "The Picture in Picture seek timed out."
        case .pictureInPictureTimedOut(operation: .restoreInterface):
            "The playback interface did not finish restoring before Picture in Picture closed."
        }
    }
}
