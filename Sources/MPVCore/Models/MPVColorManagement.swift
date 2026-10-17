import Foundation

/// SDR output precision and gamut, independent of extended dynamic range.
/// - Note: Has no effect with sample-buffer output. AVFoundation manages precision.
public enum MPVSDROutputPolicy: String, CaseIterable, Equatable, Sendable {

    /// Uses linear floating-point Display P3 on wide-gamut screens and 8-bit sRGB elsewhere.
    case automatic
    /// Uses 8-bit sRGB output with renderer dithering for compatibility.
    case compatibility8Bit
    /// Uses linear floating-point output in the screen's supported standard gamut.
    case highPrecision
}

/// Display color conversion settings applied when creating a player.
public struct MPVColorManagement: Equatable, Sendable {

    // MARK: - Types

    /// The profile or calibration used for display color conversion.
    public enum DisplayProfile: Equatable, Sendable {

        /// ColorSync converts the accurately tagged layer to the current display.
        /// Disables mpv's automatic ICC selection to avoid a second transform.
        case automatic
        /// A calibrated RGB display profile for SDR Metal output on macOS.
        /// libplacebo handles the conversion. MPVUI tags the layer with the current
        /// system display profile so ColorSync performs an identity conversion.
        /// Use a profile calibrated for the connected screen. This setting does
        /// not install the profile globally.
        case calibratedICC(URL, intent: RenderingIntent = .relativeColorimetric)
        /// A calibrated `.cube` LUT that converts the stated input encoding to
        /// display device RGB. Requires SDR Metal output on macOS and a file
        /// calibrated for the connected display. Cannot be combined with ICC conversion.
        case calibratedLUT(URL, input: LUTInput = .rec709Gamma24)
    }

    /// The color encoding expected by a display calibration LUT.
    public enum LUTInput: String, CaseIterable, Equatable, Sendable {

        /// sRGB primaries and transfer function.
        case sRGB
        /// Rec.709 primaries with a gamma 2.4 transfer function.
        case rec709Gamma24
        /// Display P3 primaries with the sRGB transfer function.
        case displayP3SRGB
    }

    /// The ICC intent used to map source colors to the display.
    public enum RenderingIntent: Int, CaseIterable, Equatable, Sendable {

        /// Preserves perceived color relationships within the display gamut.
        case perceptual = 0
        /// Maps colors relative to the display white point.
        case relativeColorimetric = 1
        /// Prioritizes vivid colors over color accuracy.
        case saturation = 2
        /// Preserves the source white point in the conversion.
        case absoluteColorimetric = 3
    }

    /// How to interpret SDR transfer characteristics for display.
    public enum SDRViewing: String, CaseIterable, Equatable, Sendable {

        /// Respects the source's tagged transfer function, including BT.1886.
        /// sRGB is its piecewise curve, not an implicit power-2.2 approximation.
        case reference
        /// Preserves legacy SDR code values when using 8-bit sRGB output.
        /// Has no effect on linear floating-point output or ICC-managed conversion.
        case legacyDisplay
    }

    // MARK: - Numeric options

    /// SDR reference white used in HDR mapping, in cd/m². This describes the
    /// rendering model. It does not set or measure physical screen luminance.
    /// Clamped to `10...1000` and rounded. Non-finite values use 203.
    /// - Note: Overrides have no effect with sample-buffer output.
    public let referenceWhite: Double

    // MARK: - Policies

    /// The requested display conversion profile.
    /// - Note: Overrides have no effect with sample-buffer output.
    public let displayProfile: DisplayProfile

    /// The requested SDR viewing behavior.
    /// - Note: Overrides have no effect with sample-buffer output.
    public let sdrViewing: SDRViewing

    /// Creates color settings with reference white clamped to `10...1000` cd/m².
    public init(
        displayProfile: DisplayProfile = .automatic,
        referenceWhite: Double = 203,
        sdrViewing: SDRViewing = .reference
    ) {
        self.displayProfile = displayProfile
        self.referenceWhite = Self.normalizeReferenceWhite(referenceWhite)
        self.sdrViewing = sdrViewing
    }

    private static func normalizeReferenceWhite(_ value: Double) -> Double {
        value.isFinite ? min(1000, max(10, value)).rounded() : 203
    }
}

/// The configured color output, separate from physical display measurements.
public struct MPVRenderColorStatus: Equatable, Sendable {

    /// The component responsible for display color conversion.
    public enum ConversionOwner: String, Equatable, Sendable {

        /// The component responsible for conversion is unknown.
        case unknown
        /// ColorSync converts the tagged layer for the display.
        case colorSync
        /// libplacebo applies a calibrated ICC display profile.
        case libplaceboCalibratedICC
        /// libplacebo applies a calibrated display LUT.
        case libplaceboCalibratedLUT
        /// AVFoundation manages native sample-buffer color conversion.
        case avFoundation
    }

    /// The configured output pixel precision.
    public enum Precision: String, Equatable, Sendable {

        /// The output precision is unknown.
        case unknown
        /// Uses 8-bit normalized color components.
        case unorm8
        /// Uses 16-bit floating-point color components.
        case float16
        /// Native output chooses precision from the source.
        case sourceManaged
    }

    /// The reason for using a fallback color configuration.
    public enum FallbackReason: String, Equatable, Sendable {

        /// Calibrated ICC output requires macOS.
        case calibratedICCRequiresMacOS
        /// Calibrated ICC output requires SDR Metal rendering.
        case calibratedICCRequiresSDRMetal
        /// The selected file is not a usable RGB display profile.
        case invalidRGBDisplayProfile
        /// The selected calibration LUT is invalid or unsupported.
        case invalidCalibrationLUT
        /// The current system display profile is unavailable.
        case currentDisplayProfileUnavailable
        /// Native output manages pixel precision itself.
        case nativeManagesPrecision
    }

    /// A color status with no known output configuration.
    public static let unknown = Self()
    /// The component performing display color conversion.
    public let conversionOwner: ConversionOwner
    /// The configured output pixel precision.
    public let precision: Precision
    /// The renderer's target color primaries, when known.
    public let targetPrimaries: String?
    /// The renderer's target transfer function, when known.
    public let targetTransfer: String?
    /// A description of the selected system profile, not a calibration claim.
    public let displayProfileName: String?
    /// The calibrated ICC profile in use, if any.
    public let calibratedProfileURL: URL?
    /// The display calibration LUT in use, if any.
    public let calibratedLUTURL: URL?
    /// The configured SDR reference white in cd/m², when known.
    public let referenceWhite: Double?
    /// The applied SDR viewing behavior, when known.
    public let sdrViewing: MPVColorManagement.SDRViewing?
    /// The reason for replacing the requested color configuration, if any.
    public let fallbackReason: FallbackReason?

    package init(
        conversionOwner: ConversionOwner = .unknown,
        precision: Precision = .unknown,
        targetPrimaries: String? = nil,
        targetTransfer: String? = nil,
        displayProfileName: String? = nil,
        calibratedProfileURL: URL? = nil,
        calibratedLUTURL: URL? = nil,
        referenceWhite: Double? = nil,
        sdrViewing: MPVColorManagement.SDRViewing? = nil,
        fallbackReason: FallbackReason? = nil
    ) {
        self.conversionOwner = conversionOwner
        self.precision = precision
        self.targetPrimaries = targetPrimaries
        self.targetTransfer = targetTransfer
        self.displayProfileName = displayProfileName
        self.calibratedProfileURL = calibratedProfileURL
        self.calibratedLUTURL = calibratedLUTURL
        self.referenceWhite = referenceWhite
        self.sdrViewing = sdrViewing
        self.fallbackReason = fallbackReason
    }
}
