import Foundation

/// GPU rendering choices. Presets are workload choices, not measured battery-life guarantees.
/// Configure before creating the player; changes require a new player/load.
public struct MPVRenderingQuality: Equatable, Sendable {
    /// A base set of GPU rendering options.
    public enum Preset: String, CaseIterable, Sendable {
        /// Selects battery in Low Power Mode, otherwise balanced, when the renderer is created.
        case automatic
        /// Uses lower-cost rendering options.
        case battery
        /// Balances rendering cost and filtering quality.
        case balanced
        /// Uses more demanding scaling and filtering options.
        case highQuality
    }

    /// A filter for resizing video or chroma planes.
    public enum Scaling: String, CaseIterable, Sendable {
        /// Bilinear interpolation.
        case bilinear
        /// Bicubic interpolation.
        case bicubic
        /// Lanczos scaling.
        case lanczos
        /// Elliptical weighted-average Lanczos scaling.
        case ewaLanczos = "ewa_lanczos"
        /// A sharper elliptical weighted-average Lanczos filter.
        case ewaLanczosSharp = "ewa_lanczossharp"
    }

    /// A method for reducing output quantization artifacts.
    public enum Dithering: String, CaseIterable, Sendable {
        /// Uses mpv's fruit dithering method.
        case automatic
        /// Disables output dithering.
        case disabled
        /// Uses an ordered dithering pattern.
        case ordered
        /// Uses mpv's fruit dithering method.
        case fruit
        /// Diffuses quantization error into neighboring pixels.
        case errorDiffusion = "error-diffusion"
    }

    /// A curve for mapping brightness into the output range.
    public enum ToneMapping: String, CaseIterable, Sendable {
        /// Lets mpv choose the tone-mapping curve.
        case automatic = "auto"
        /// Uses spline tone mapping.
        case spline
        /// Uses Mobius tone mapping.
        case mobius
        /// Uses Reinhard tone mapping.
        case reinhard
        /// Uses Hable tone mapping.
        case hable
        /// Clips brightness outside the output range.
        case clip
        /// Uses the BT.2390 tone-mapping curve.
        case bt2390 = "bt.2390"
    }

    /// A method for fitting colors into the output gamut.
    public enum GamutMapping: String, CaseIterable, Sendable {
        /// Lets mpv choose the gamut-mapping method.
        case automatic = "auto"
        /// Uses perceptual gamut mapping.
        case perceptual
        /// Uses relative colorimetric gamut mapping.
        case relative
        /// Prioritizes color saturation.
        case saturation
        /// Uses absolute colorimetric gamut mapping.
        case absolute
        /// Desaturates colors to fit the output gamut.
        case desaturate
        /// Darkens colors to fit the output gamut.
        case darken
        /// Clips colors outside the output gamut.
        case clip
    }

    /// Whether the renderer estimates peak brightness from frames.
    public enum PeakDetection: String, CaseIterable, Sendable {
        /// Lets mpv choose whether to detect peak brightness.
        case automatic = "auto"
        /// Enables frame-based peak brightness detection.
        case enabled = "yes"
        /// Disables frame-based peak brightness detection.
        case disabled = "no"
    }

    /// A creative input LUT. Display calibration belongs to ``MPVColorManagement``.
    /// Conversion LUTs are deliberately excluded because they replace output color management.
    public struct LUT: Equatable, Sendable {
        /// The input encoding used by a creative LUT.
        public enum Domain: String, CaseIterable, Sendable {
            /// Uses the source's native color encoding.
            case native
            /// Uses mpv's normalized LUT input encoding.
            case normalized
        }

        /// The local LUT file URL.
        public var url: URL
        /// The color encoding expected by the LUT.
        public var domain: Domain
        /// Creates a creative LUT with the specified input encoding.
        public init(url: URL, domain: Domain = .native) {
            self.url = url
            self.domain = domain
        }
    }

    /// The base preset used before applying overrides.
    public var preset: Preset
    /// The video scaling filter; nil uses the preset.
    public var scaling: Scaling?
    /// The chroma scaling filter; nil uses the preset.
    public var chromaScaling: Scaling?
    /// Clamped to 0...1 by the resolver; nil uses the preset.
    public var antiringing: Double?
    /// Chroma antiringing strength, clamped to 0...1; nil uses the preset.
    public var chromaAntiringing: Double?
    /// Whether to reduce color banding; nil uses the preset.
    public var debanding: Bool?
    /// Output dithering; nil uses the preset.
    public var dithering: Dithering?
    /// The tone-mapping curve; nil uses the preset.
    public var toneMapping: ToneMapping?
    /// The gamut-mapping method; nil uses the preset.
    public var gamutMapping: GamutMapping?
    /// Peak brightness detection; nil uses the preset.
    public var peakDetection: PeakDetection?
    /// Local mpv shader files, applied in order.
    public var shaders: [URL]
    /// An optional creative input LUT.
    public var lut: LUT?

    /// Creates rendering settings with optional preset overrides.
    public init(
        preset: Preset = .automatic,
        scaling: Scaling? = nil,
        chromaScaling: Scaling? = nil,
        antiringing: Double? = nil,
        chromaAntiringing: Double? = nil,
        debanding: Bool? = nil,
        dithering: Dithering? = nil,
        toneMapping: ToneMapping? = nil,
        gamutMapping: GamutMapping? = nil,
        peakDetection: PeakDetection? = nil,
        shaders: [URL] = [],
        lut: LUT? = nil
    ) {
        self.preset = preset
        self.scaling = scaling
        self.chromaScaling = chromaScaling
        self.antiringing = antiringing
        self.chromaAntiringing = chromaAntiringing
        self.debanding = debanding
        self.dithering = dithering
        self.toneMapping = toneMapping
        self.gamutMapping = gamutMapping
        self.peakDetection = peakDetection
        self.shaders = shaders
        self.lut = lut
    }
}

/// Requested and accepted renderer quality settings.
public struct MPVRenderingQualityStatus: Equatable, Sendable {
    /// The rendering settings requested by the caller.
    public var requested: MPVRenderingQuality
    /// The preset selected after resolving automatic behavior.
    public var resolvedPreset: MPVRenderingQuality.Preset
    /// The video output used by the renderer.
    public var backend: MPVPlayerConfiguration.VideoOutput
    /// Accepted mpv option readback. This describes configuration, not measured image quality.
    public var effectiveOptions: [String: String]
    /// Requested features that the renderer cannot apply.
    public var unsupportedFeatures: [String]
    /// Automatic resolves Low Power Mode once when the renderer is created.
    public var requiresReload: Bool {
        true
    }

    /// Creates a snapshot of requested and accepted rendering settings.
    public init(
        requested: MPVRenderingQuality = .init(),
        resolvedPreset: MPVRenderingQuality.Preset = .balanced,
        backend: MPVPlayerConfiguration.VideoOutput = .metal,
        effectiveOptions: [String: String] = [:],
        unsupportedFeatures: [String] = []
    ) {
        self.requested = requested
        self.resolvedPreset = resolvedPreset
        self.backend = backend
        self.effectiveOptions = effectiveOptions
        self.unsupportedFeatures = unsupportedFeatures
    }
}
