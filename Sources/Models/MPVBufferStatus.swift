/// A snapshot of mpv's network and demuxer buffering state.
public struct MPVBufferStatus: Equatable, Sendable {
    /// Whether playback is currently waiting for buffered media.
    public let isBuffering: Bool

    /// Progress toward resuming playback, from `0...1`, rather than total download progress.
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

    /// Creates a snapshot, clamping negative bytes, input rate, and buffered duration to zero.
    /// Progress is clamped to `0...1`; non-finite progress becomes zero.
    init(
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
        self.secondsBufferedAhead = secondsBufferedAhead.clampPositiveOrZero
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
