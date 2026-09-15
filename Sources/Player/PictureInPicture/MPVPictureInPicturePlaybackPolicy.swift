import CoreMedia
import Foundation

/// Timeline calculations shared by the native sample-buffer PiP integration.
/// The native VO owns the timebase; these calculations must not change its rate
/// or substitute a second clock for the player's presentation timeline.
enum MPVPictureInPicturePlaybackPolicy {
    static func playbackTimeRange(
        hasMedia: Bool,
        state: MPVPlaybackState,
        duration: Duration,
        displayTime: CMTime
    ) -> CMTimeRange {
        guard hasMedia else { return .invalid }
        switch state {
        case .idle, .loading, .stopped, .failed:
            return .invalid
        case .ready, .playing, .paused, .buffering, .seeking, .ended:
            break
        }

        // Unknown duration is a live timeline, never a zero-length movie.
        guard duration > .zero else {
            return CMTimeRange(start: .zero, duration: .positiveInfinity)
        }

        let mediaEnd = CMTime(seconds: duration.seconds, preferredTimescale: 600)
        guard mediaEnd.isNumeric else { return .invalid }
        guard displayTime.isNumeric else {
            return CMTimeRange(start: .zero, end: mediaEnd)
        }

        // Apple requires a finite range to contain the display timebase. Allow
        // negative initial PTS and small end-of-file clock overshoots. Ranges
        // are half-open, so the current time needs at least one extra tick.
        let start = CMTimeMinimum(.zero, displayTime)
        let end = CMTimeMaximum(
            mediaEnd,
            CMTimeAdd(displayTime, CMTime(value: 1, timescale: 600))
        )
        return CMTimeRange(start: start, end: end)
    }

    static func seekTarget(
        position: Duration,
        interval: CMTime,
        duration: Duration,
        isSeekable: Bool
    ) -> Duration? {
        guard isSeekable, interval.isNumeric, interval.seconds.isFinite else { return nil }
        // Saturate before converting to Duration, avoiding overflow for valid
        // CMTime values whose timescale is very small.
        let seconds = position.seconds + interval.seconds
        guard seconds.isFinite else { return nil }
        let upperBound = duration > .zero ? duration.seconds : Double(Int64.max / 2)
        return .seconds(min(max(seconds, 0), upperBound))
    }
}
