import Foundation

/// SDR precision and gamut are independent of extended dynamic range.
public enum MPVSDROutputPolicy: String, CaseIterable, Equatable, Sendable {
    /// Linear float Display P3 on wide-gamut screens; 8-bit sRGB elsewhere.
    case automatic
    /// Explicit 8-bit sRGB compatibility output, with renderer dithering.
    case compatibility8Bit
    /// Linear float output in the screen's supported standard gamut.
    case highPrecision
}

/// The display conversion contract. Changes require a new player configuration.
public struct MPVColorManagement: Equatable, Sendable {
    /// The profile or calibration used for display color conversion.
    public enum DisplayProfile: Equatable, Sendable {
        /// ColorSync converts the accurately tagged layer to the current display.
        /// mpv's automatic ICC selection is disabled to avoid a second transform.
        case automatic
        /// macOS SDR only. libplacebo converts to this calibrated RGB display
        /// profile. The layer is tagged with the current system display profile
        /// so ColorSync performs an identity display conversion. Use a profile
        /// calibrated for the connected screen; this does not install it globally.
        case calibratedICC(URL, intent: RenderingIntent = .relativeColorimetric)
        /// A calibrated .cube LUT converting the stated input encoding to
        /// display device RGB. Mutually exclusive with ICC conversion. macOS
        /// SDR Metal only; the file must be made for the connected display.
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

    /// How SDR transfer characteristics are interpreted for display.
    public enum SDRViewing: String, CaseIterable, Equatable, Sendable {
        /// Respect the source's tagged transfer function, including BT.1886.
        /// sRGB is its piecewise curve, not an implicit power-2.2 approximation.
        case reference
        /// Preserve legacy SDR code values when using 8-bit sRGB output.
        /// Has no effect on linear float output or ICC-managed conversion.
        case legacyDisplay
    }

    /// The requested display conversion profile.
    public var displayProfile: DisplayProfile
    /// The requested SDR viewing behavior.
    public var sdrViewing: SDRViewing
    private var storedReferenceWhite: Double
    /// SDR reference white used in HDR mapping, in cd/m². This describes the
    /// rendering model; it does not set or measure physical screen luminance.
    public var referenceWhite: Double {
        get { storedReferenceWhite }
        set { storedReferenceWhite = Self.normalizeReferenceWhite(newValue) }
    }

    /// Creates color settings with reference white clamped to 10...1000 cd/m².
    public init(
        displayProfile: DisplayProfile = .automatic,
        sdrViewing: SDRViewing = .reference,
        referenceWhite: Double = 203
    ) {
        self.displayProfile = displayProfile
        self.sdrViewing = sdrViewing
        storedReferenceWhite = Self.normalizeReferenceWhite(referenceWhite)
    }

    private static func normalizeReferenceWhite(_ value: Double) -> Double {
        value.isFinite ? min(1000, max(10, value)).rounded() : 203
    }
}

/// Configured output contract, separate from physical display measurements.
public struct MPVRenderColorStatus: Equatable, Sendable {
    /// The component responsible for display color conversion.
    public enum ConversionOwner: String, Equatable, Sendable {
        /// The conversion owner is not known.
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
        /// The output precision is not known.
        case unknown
        /// Uses 8-bit normalized color components.
        case unorm8
        /// Uses 16-bit floating-point color components.
        case float16
        /// Native output chooses precision from the source.
        case sourceManaged
    }

    /// Why the requested color configuration could not be applied.
    public enum FallbackReason: String, Equatable, Sendable {
        /// Calibrated ICC output requires macOS.
        case calibratedICCRequiresMacOS
        /// Calibrated ICC output requires SDR Metal rendering.
        case calibratedICCRequiresSDRMetal
        /// The selected file is not a usable RGB display profile.
        case invalidRGBDisplayProfile
        /// The selected calibration LUT is invalid or unsupported.
        case invalidCalibrationLUT
        /// The current system display profile could not be obtained.
        case currentDisplayProfileUnavailable
        /// Native output manages pixel precision itself.
        case nativeManagesPrecision
    }

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
    /// Why the requested color configuration was replaced, if any.
    public let fallbackReason: FallbackReason?

    init(
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

    /// A color status with no known output configuration.
    public static let unknown = Self()
}
