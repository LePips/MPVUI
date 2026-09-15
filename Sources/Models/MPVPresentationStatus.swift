/// Requested behavior and configured output are distinct from observed screen
/// presentation. Apple does not expose a measurement of final screen luminance.
public struct MPVPresentationStatus: Equatable, Sendable {
    /// A configured or observed output dynamic range.
    public enum DynamicRange: String, Equatable, Sendable {
        /// The output dynamic range is not known.
        case unknown
        /// The operating system chooses output conversion from sample metadata.
        case automatic
        /// Standard dynamic range output.
        case sdr
        /// High dynamic range output.
        case hdr
        /// HDR output constrained to the configured brightness budget.
        case constrainedHDR
    }

    /// Why the requested presentation configuration could not be used.
    public enum FallbackReason: Equatable, Sendable {
        /// The output route does not support the requested policy.
        case unsupportedPolicy
        /// The linked native-output binary predates subtitle luminance control.
        case unsupportedSubtitleLuminance
        /// The selected display does not report HDR support.
        case displayDoesNotSupportHDR
        /// The display currently lacks the required EDR headroom.
        case insufficientCurrentHeadroom
        /// Native video output is unavailable for the supplied reason.
        case nativeOutputUnavailable(String)
        /// A live output configuration update failed with the supplied reason.
        case liveConfigurationFailed(String)
    }

    /// The HDR policy requested by the caller.
    public let requestedPolicy: MPVPlayerConfiguration.HDRPolicy
    /// The video output used for presentation.
    public let backend: MPVPlayerConfiguration.VideoOutput
    /// Describes the layer and renderer configuration, not measured luminance.
    public let configuredDynamicRange: DynamicRange
    /// Unknown unless the OS can establish the actual presentation mode.
    public let actualDynamicRange: DynamicRange
    /// Why presentation differs from the requested policy, if known.
    public let fallbackReason: FallbackReason?

    init(
        requestedPolicy: MPVPlayerConfiguration.HDRPolicy = .automatic,
        backend: MPVPlayerConfiguration.VideoOutput = .metal,
        configuredDynamicRange: DynamicRange = .unknown,
        actualDynamicRange: DynamicRange = .unknown,
        fallbackReason: FallbackReason? = nil
    ) {
        self.requestedPolicy = requestedPolicy
        self.backend = backend
        self.configuredDynamicRange = configuredDynamicRange
        self.actualDynamicRange = actualDynamicRange
        self.fallbackReason = fallbackReason
    }

    /// A status with no known presentation mode.
    public static let unknown = Self()
}
