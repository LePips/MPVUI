/// Deinterlacing settings applied when creating a player.
/// Produces one frame per field to preserve temporal motion.
public struct MPVDeinterlacePolicy: Equatable, Sendable {

    // MARK: - Types

    /// The filter used to reconstruct progressive frames.
    public enum Algorithm: String, CaseIterable, Sendable {
        /// mpv chooses a hardware filter when supported, otherwise bwdif.
        case automatic
        /// Uses the bwdif software deinterlacer.
        case bwdif
        /// Uses the yadif software deinterlacer.
        case yadif
    }

    /// The temporal order of interlaced fields.
    public enum FieldOrder: String, CaseIterable, Sendable {
        /// Uses the detected or reported field order.
        case automatic = "auto"
        /// Treats the top field as earlier in time.
        case topFirst = "tff"
        /// Treats the bottom field as earlier in time.
        case bottomFirst = "bff"
    }

    /// When deinterlacing should be applied.
    public enum Mode: String, CaseIterable, Sendable {
        /// Leaves deinterlacing disabled.
        case disabled
        /// Deinterlaces frames identified as interlaced.
        case automatic
        /// Applies deinterlacing regardless of interlace tags.
        case forced
    }

    // MARK: - Boolean options

    /// Run idet before an explicitly selected software filter to recover bad field tags.
    /// Detection itself requires software-accessible pixels, including progressive video.
    public let analyzeFieldOrder: Bool

    // MARK: - Policies

    /// The requested deinterlacing filter.
    public let algorithm: Algorithm

    /// The requested field order or automatic detection.
    public let fieldOrder: FieldOrder

    /// When to enable deinterlacing.
    public let mode: Mode

    /// Creates a deinterlacing policy, disabled by default.
    public init(
        algorithm: Algorithm = .automatic,
        analyzeFieldOrder: Bool = false,
        fieldOrder: FieldOrder = .automatic,
        mode: Mode = .disabled
    ) {
        self.algorithm = algorithm
        self.analyzeFieldOrder = analyzeFieldOrder
        self.fieldOrder = fieldOrder
        self.mode = mode
    }
}

/// Requested deinterlacing settings and observed filter state.
public struct MPVDeinterlaceStatus: Equatable, Sendable {
    /// The deinterlacing policy requested by the caller.
    public var requested: MPVDeinterlacePolicy = .init()
    /// Current displayed-frame metadata; nil means mpv cannot report it.
    public var outputFrameIsInterlaced: Bool?
    /// Actual mpv automatic deinterlacer state; explicit lavfi filters may be unknown.
    public var isActive: Bool?
    /// The effective deinterlacing filter description, when available.
    public var effectiveFilter: String?
    /// Whether the configured filter requires software-accessible frames.
    public var requiresSoftwareFrames: Bool?
    /// An explanation of the current deinterlacing configuration, if available.
    public var reason: String?
    /// Creates a status with no observed deinterlacing state.
    public init() {}
}
