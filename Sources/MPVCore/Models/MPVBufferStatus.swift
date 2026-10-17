/// A snapshot of mpv's network and demuxer buffering state.
public struct MPVBufferStatus: Equatable, Sendable {

    /// A snapshot representing an unbuffered player.
    public static let empty = Self()

    /// Whether playback is waiting for buffered media.
    public let isBuffering: Bool

    /// Progress toward resuming playback, from `0...1`, rather than total download progress.
    public let progress: Double

    /// The amount of playable media buffered after the current position.
    public let secondsBufferedAhead: Duration

    /// The furthest buffered timeline position, when mpv reports one.
    public let bufferedEnd: Duration?

    /// The number of demuxed bytes available after the current position.
    public let bytesAhead: Int64

    /// Total demuxer-cache bytes, including retained data behind the current
    /// position. `nil` means the native cache did not report its allocation.
    public let totalBytes: Int64?

    /// The current input rate in bytes per second.
    public let inputRate: Int64

    /// The timeline ranges available for seeking in the current source.
    public let seekableRanges: [ClosedRange<Duration>]

    /// Creates a snapshot, clamping negative bytes, input rate, and buffered duration to zero.
    /// Clamps progress to `0...1` and replaces non-finite progress with zero.
    package init(
        isBuffering: Bool = false,
        progress: Double = 0,
        secondsBufferedAhead: Duration = .zero,
        bufferedEnd: Duration? = nil,
        bytesAhead: Int64 = 0,
        totalBytes: Int64? = nil,
        inputRate: Int64 = 0,
        seekableRanges: [ClosedRange<Duration>] = []
    ) {
        self.isBuffering = isBuffering
        self.progress = Self.normalizedProgress(progress)
        self.secondsBufferedAhead = secondsBufferedAhead.clampPositiveOrZero
        self.bufferedEnd = bufferedEnd
        self.bytesAhead = max(0, bytesAhead)
        self.totalBytes = totalBytes.map { max(0, $0) }
        self.inputRate = max(0, inputRate)
        self.seekableRanges = seekableRanges
    }

    private static func normalizedProgress(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return clamp(value, to: 0 ... 1)
    }
}
