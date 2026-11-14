/// The outcome of preparing the display while playback remains paused.
/// Results describe platform observations, not the physical HDMI output.
public enum MPVDisplayMatchingPreparationResult: Equatable, Sendable {

    /// The platform reported a switch and then remained idle for the settling interval.
    case switchCompleted

    /// Criteria were submitted, but no switch was reported during the settling interval.
    /// The current mode may already match, or the display may not support the requested mode.
    case noSwitchObserved

    /// Display matching is disabled in the player configuration or system settings.
    case disabled

    /// No active display endpoint or representable video format is available.
    case unavailable

    /// Load with `playAutomatically: false` before preparing the display.
    case requiresPausedPlayback

    /// Metadata or a mode switch did not settle before the deadline.
    case timedOut

    /// Cancellation, a new request, a media change, or surface retirement ended the wait.
    case cancelled
}
