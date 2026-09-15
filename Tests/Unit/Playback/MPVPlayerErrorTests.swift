@testable import MPVUI
import Testing

@Suite(.tags(.unit))
struct MPVPlayerErrorTests {
    @Test(arguments: [
        (MPVPlayerError.clientCreationFailed, "Unable to create the mpv client."),
        (.clientUnavailable, "mpv is not available."),
        (.initializationFailed(context: "Configure output", code: -4, message: "Invalid option"), "Configure output: Invalid option"),
        (.commandFailed(context: "Seek", code: -12, message: "Command failed"), "Seek: Command failed"),
        (.loadFailed(code: -13, message: "File not found"), "Load media: File not found"),
        (.playbackFailed(code: -14, message: "Decoder failed"), "Playback failed: Decoder failed"),
        (.eventQueueOverflow, "The mpv event queue overflowed; player state was refreshed."),
        (.pictureInPictureNotReady, "Picture in Picture is not ready for the current video."),
        (.pictureInPictureFailed(operation: .start, message: "Host rejected presentation"), "Host rejected presentation"),
        (.invalidSubtitleTrack(.init(type: .subtitle, mpvID: 99)), "Choose a subtitle track from the currently loaded media."),
        (
            .pictureInPictureUnsupported,
            "Picture in Picture requires native sample-buffer output on a supported iOS device, or the macOS PiP host."
        ),
    ])
    func `failures retain actionable context for the caller`(error: MPVPlayerError, expected: String) {
        #expect(error.localizedDescription == expected)
    }

    @Test(arguments: [
        (MPVPlayerError.PictureInPictureOperation.start, "Picture in Picture did not start before the system transition timed out."),
        (.stop, "Picture in Picture did not finish closing before the system transition timed out."),
        (.seek, "The Picture in Picture seek timed out."),
        (.restoreInterface, "The playback interface did not finish restoring before Picture in Picture closed."),
    ])
    func `PiP timeout tells the caller which operation stalled`(operation: MPVPlayerError.PictureInPictureOperation, expected: String) {
        #expect(MPVPlayerError.pictureInPictureTimedOut(operation: operation).localizedDescription == expected)
    }
}
