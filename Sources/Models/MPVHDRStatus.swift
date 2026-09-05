/// Describes the source and output HDR state for the current media.
public struct MPVHDRStatus: Equatable, Sendable {
    /// Color primaries reported by the source, such as `bt.2020`.
    public let primaries: String?

    /// The source signal's transfer function.
    public let transferFunction: MPVTransferFunction

    /// Mastering-display minimum luminance in nits, when reported.
    public let minimumLuminance: Double?

    /// Mastering-display maximum luminance in nits, when reported.
    public let maximumLuminance: Double?

    /// Maximum Content Light Level in nits, when reported.
    public let maxContentLightLevel: Double?

    /// Maximum Frame-Average Light Level in nits, when reported.
    public let maxFrameAverageLightLevel: Double?

    /// The signal peak reported or inferred by mpv, when available.
    public let signalPeak: Double?

    /// Whether the selected output display supports HDR presentation.
    public let isDisplayHDRCapable: Bool

    /// Whether the output pipeline is currently presenting in HDR.
    public let isHDRActive: Bool

    /// Creates an HDR status snapshot.
    ///
    /// Non-finite or negative luminance and signal-peak values are discarded.
    /// Source HDR detection is always derived from `transferFunction`, never
    /// from wide-gamut primaries alone.
    ///
    /// - Parameters:
    ///   - primaries: Source color primaries, when reported.
    ///   - transferFunction: The source transfer function.
    ///   - minimumLuminance: Mastering-display minimum luminance in nits.
    ///   - maximumLuminance: Mastering-display maximum luminance in nits.
    ///   - maxContentLightLevel: Maximum Content Light Level in nits.
    ///   - maxFrameAverageLightLevel: Maximum Frame-Average Light Level in nits.
    ///   - signalPeak: The signal peak reported or inferred by mpv.
    ///   - isDisplayHDRCapable: Whether the selected display supports HDR.
    ///   - isHDRActive: Whether the output pipeline is currently using HDR.
    public init(
        primaries: String? = nil,
        transferFunction: MPVTransferFunction = .unknown,
        minimumLuminance: Double? = nil,
        maximumLuminance: Double? = nil,
        maxContentLightLevel: Double? = nil,
        maxFrameAverageLightLevel: Double? = nil,
        signalPeak: Double? = nil,
        isDisplayHDRCapable: Bool = false,
        isHDRActive: Bool = false
    ) {
        self.primaries = primaries
        self.transferFunction = transferFunction
        self.minimumLuminance = Self.normalizedNonnegative(minimumLuminance)
        self.maximumLuminance = Self.normalizedNonnegative(maximumLuminance)
        self.maxContentLightLevel = Self.normalizedNonnegative(maxContentLightLevel)
        self.maxFrameAverageLightLevel = Self.normalizedNonnegative(maxFrameAverageLightLevel)
        self.signalPeak = Self.normalizedNonnegative(signalPeak)
        self.isDisplayHDRCapable = isDisplayHDRCapable
        self.isHDRActive = isHDRActive
    }

    /// Whether the source content is HDR.
    public var isHDRContent: Bool {
        transferFunction.isHDR
    }

    /// An SDR status with no mastering metadata or active HDR output.
    public static let sdr = Self()

    private static func normalizedNonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}
