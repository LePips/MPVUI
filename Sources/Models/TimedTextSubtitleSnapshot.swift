/// A complete text subtitle presentation over a half-open source-time interval.
///
/// Times are in the media timeline, before subtitle delay or speed adjustments.
/// Overlapping cues appear together in ``snapshot``.
public struct TimedTextSubtitleSnapshot: Sendable, Hashable {
    /// The inclusive start of this presentation.
    public let startTime: Duration

    /// The exclusive end of this presentation.
    public let endTime: Duration

    /// All text regions presented during this interval.
    public let snapshot: TextSubtitleSnapshot

    /// Whether the given source timestamp is inside this presentation.
    public func contains(_ timestamp: Duration) -> Bool {
        startTime <= timestamp && timestamp < endTime
    }
}
