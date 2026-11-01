/// Demuxer packet limits, separate from decoder and GPU allocations.
public struct MPVCacheConfiguration: Equatable, Sendable {

    /// When mpv enables its demuxer cache and retained seek history.
    public enum Mode: String, Equatable, Sendable {

        /// Uses mpv's source classification, caching network streams.
        case automatic = "auto"
        /// Caches local sources as well as network streams.
        case enabled = "yes"
        /// Disables the demuxer cache.
        case disabled = "no"
    }

    /// The requested cache policy.
    public let mode: Mode
    /// Forward packet limit in bytes, clamped to zero or greater.
    public let maximumBytes: Int64
    /// Retained packet history in bytes, clamped to zero or greater.
    public let maximumBackBytes: Int64

    /// Creates a bounded cache with 128 MiB ahead and 32 MiB of seek history.
    /// Smaller limits reduce buffered time at high bitrates. Memory is allocated as packets arrive.
    public init(mode: Mode = .automatic, maximumBytes: Int64 = 128 * 1024 * 1024, maximumBackBytes: Int64 = 32 * 1024 * 1024) {
        self.mode = mode
        self.maximumBytes = max(0, maximumBytes)
        self.maximumBackBytes = max(0, maximumBackBytes)
    }
}
