/// A snapshot of mpv's network and demuxer buffering state.
public struct MPVBufferStatus: Equatable, Sendable {
    /// Whether playback is currently waiting for buffered media.
    public let isBuffering: Bool

    /// Progress toward mpv's threshold for resuming buffered playback.
    ///
    /// This is normalized to `0...1`; it is not the fraction of the complete
    /// media timeline that has been downloaded.
    public let progress: Double

    /// The amount of playable media buffered after the current position.
    public let secondsBufferedAhead: Duration

    /// The furthest buffered timeline position, when mpv reports one.
    public let bufferedEnd: Duration?

    /// The number of demuxed bytes available after the current position.
    public let bytesAhead: Int64

    /// The current input rate in bytes per second.
    public let inputRate: Int64

    /// Timeline ranges to which the current source can seek.
    public let seekableRanges: [ClosedRange<Duration>]

    /// Creates a buffering snapshot.
    ///
    /// Negative byte, rate, and buffered-duration values are normalized to
    /// zero. Non-finite progress values are also treated as zero.
    ///
    /// - Parameters:
    ///   - isBuffering: Whether playback is waiting for buffered media.
    ///   - progress: Rebuffer/resume progress; values are clamped to `0...1`.
    ///   - secondsBufferedAhead: Playable seconds available after the current position.
    ///   - bufferedEnd: The furthest buffered position, when known.
    ///   - bytesAhead: Demuxed bytes available after the current position.
    ///   - inputRate: Current input rate in bytes per second.
    ///   - seekableRanges: Timeline ranges to which the source can seek.
    public init(
        isBuffering: Bool = false,
        progress: Double = 0,
        secondsBufferedAhead: Duration = .zero,
        bufferedEnd: Duration? = nil,
        bytesAhead: Int64 = 0,
        inputRate: Int64 = 0,
        seekableRanges: [ClosedRange<Duration>] = []
    ) {
        self.isBuffering = isBuffering
        self.progress = Self.normalizedProgress(progress)
        self.secondsBufferedAhead = max(.zero, secondsBufferedAhead)
        self.bufferedEnd = bufferedEnd
        self.bytesAhead = max(0, bytesAhead)
        self.inputRate = max(0, inputRate)
        self.seekableRanges = seekableRanges
    }

    /// A snapshot representing an unbuffered player.
    public static let empty = Self()

    private static func normalizedProgress(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return clamp(value, to: 0 ... 1)
    }
}
