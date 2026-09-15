/// Describes the source and output HDR state for the current media.
public struct MPVHDRStatus: Equatable, Sendable {
    /// Raw decoder metadata before mpv applies overrides or guesses. This is
    /// the closest source-signal description exposed by mpv, not bitstream proof.
    public let source: MPVVideoSignal

    /// Decoded signal after mpv's corrections, before video filters.
    public let decoded: MPVVideoSignal

    /// Filtered signal supplied to the video output, before renderer conversion.
    public let videoOutputInput: MPVVideoSignal

    /// Renderer target metadata, when reported. Never inferred from the source
    /// or the layer; native AVFoundation conversion can leave this unknown.
    public let output: MPVVideoSignal

    /// The selected output route's display capabilities.
    public let displayCapabilities: MPVDisplayCapabilities
    /// The requested and configured presentation state.
    public let presentation: MPVPresentationStatus

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

    /// Whether HDR presentation has been established by the operating system.
    /// False also includes unknown; consult ``presentation`` to distinguish it.
    public let isHDRActive: Bool

    /// Creates a snapshot, discarding non-finite or negative luminance and signal peaks.
    init(
        primaries: String? = nil,
        transferFunction: MPVTransferFunction = .unknown,
        minimumLuminance: Double? = nil,
        maximumLuminance: Double? = nil,
        maxContentLightLevel: Double? = nil,
        maxFrameAverageLightLevel: Double? = nil,
        signalPeak: Double? = nil,
        isDisplayHDRCapable: Bool = false,
        isHDRActive: Bool = false,
        source: MPVVideoSignal? = nil,
        decoded: MPVVideoSignal = .unknown,
        videoOutputInput: MPVVideoSignal = .unknown,
        output: MPVVideoSignal = .unknown,
        displayCapabilities: MPVDisplayCapabilities? = nil,
        presentation: MPVPresentationStatus? = nil
    ) {
        let source = source ?? MPVVideoSignal(
            primaries: primaries,
            transferFunction: transferFunction,
            minimumLuminance: minimumLuminance,
            maximumLuminance: maximumLuminance,
            maxContentLightLevel: maxContentLightLevel,
            maxFrameAverageLightLevel: maxFrameAverageLightLevel,
            signalPeak: signalPeak
        )
        self.source = source
        self.decoded = decoded
        self.videoOutputInput = videoOutputInput
        self.output = output
        self.displayCapabilities = displayCapabilities ?? MPVDisplayCapabilities(
            hdrSupport: isDisplayHDRCapable ? .supported : .unknown
        )
        self.presentation = presentation ?? MPVPresentationStatus(
            actualDynamicRange: isHDRActive ? .hdr : .unknown
        )
        self.primaries = source.primaries
        self.transferFunction = source.transferFunction
        self.minimumLuminance = source.minimumLuminance
        self.maximumLuminance = source.maximumLuminance
        self.maxContentLightLevel = source.maxContentLightLevel
        self.maxFrameAverageLightLevel = source.maxFrameAverageLightLevel
        self.signalPeak = source.signalPeak
        self.isDisplayHDRCapable = self.displayCapabilities.hdrSupport == .supported
        self.isHDRActive = self.presentation.actualDynamicRange == .hdr
            || self.presentation.actualDynamicRange == .constrainedHDR
    }

    /// Whether the source uses PQ or HLG. Wide-gamut primaries alone do not imply HDR.
    public var isHDRContent: Bool {
        transferFunction.isHDR
    }

    /// Empty metadata and unknown presentation; retained for source compatibility.
    public static let sdr = Self()
}
