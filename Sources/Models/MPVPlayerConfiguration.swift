/// Playback defaults and output options for ``MPVPlayer``.
///
/// Pass the configuration to the player initializer on the main actor:
///
/// ```swift
/// let configuration = MPVPlayerConfiguration(
///     autoPlay: false,
///     volume: 75,
///     videoOutput: .sampleBuffer
/// )
/// let player = MPVPlayer(configuration: configuration)
/// ```
public struct MPVPlayerConfiguration: Equatable, Sendable {
    /// The preferred video presentation backend.
    public enum VideoOutput: String, CaseIterable, Equatable, Sendable {
        /// Full gpu-next rendering through Metal/MoltenVK.
        case metal

        /// Native AVFoundation output with iOS PiP; requires the native-output Libmpv build.
        /// AVFoundation handles color conversion, bypassing gpu-next shaders and tone mapping.
        /// Unsupported native Dolby Vision falls back to Metal for that file;
        /// ``MPVPlayer/videoOutput`` reports the active backend.
        case sampleBuffer
    }

    /// The hardware-decoding strategy requested from mpv.
    public enum HardwareDecoding: String, CaseIterable, Equatable, Sendable {
        /// Let mpv select a safe hardware decoder when one is available.
        case automatic = "auto-safe"

        /// Request Apple's VideoToolbox decoder.
        case videoToolbox = "videotoolbox"

        /// Decode video in software.
        case disabled = "no"
    }

    /// How MPVUI configures HDR output and tone mapping.
    public enum HDRPolicy: String, CaseIterable, Equatable, Sendable {
        /// Match the source, display capabilities, and current output route.
        case automatic

        /// Request HDR output whenever the platform permits it.
        case always

        /// Disable HDR output and tone-map HDR sources to SDR.
        case disabled

        /// Request HDR with the system's constrained brightness policy when supported.
        case constrained

        /// Request HDR when the display and platform support it.
        public static let hdrWhenAvailable = Self.always

        /// Request SDR conversion, using a backend capable of enforcing it.
        public static let sdr = Self.disabled
    }

    /// Minimum forwarded severity; each level includes more severe messages.
    public enum LogLevel: String, CaseIterable, Equatable, Sendable {
        /// Disable mpv log forwarding.
        case none = "no"

        /// Forwards fatal errors only.
        case fatal

        /// Forwards errors and more severe messages.
        case error

        /// Forwards warnings and more severe messages.
        case warning = "warn"

        /// Forwards informational and more severe messages.
        case info

        /// Also forwards playback status updates.
        case status

        /// Also forwards verbose diagnostics.
        case verbose = "v"

        /// Also forwards debugging diagnostics.
        case debug

        /// Forward all trace messages.
        case trace
    }

    /// The default playback volume, 100 percent.
    public static let defaultVolume = 100.0

    /// The default playback rate, normal speed.
    public static let defaultPlaybackRate = 1.0

    /// The slowest playback rate accepted by mpv.
    public static let minimumPlaybackRate = 0.01

    /// The fastest playback rate accepted by mpv.
    public static let maximumPlaybackRate = 100.0

    /// The default network cache duration, ten seconds.
    public static let defaultNetworkCacheSeconds: Duration = .seconds(10)

    /// The default initial buffer duration, one second.
    public static let defaultInitialBufferSeconds: Duration = .seconds(1)

    /// The default player configuration.
    public static let `default` = Self()

    /// Whether loading a source should begin playback automatically.
    public var autoPlay: Bool

    /// Whether playback should restart after reaching the end of the media.
    public var loop: Bool

    private var storedStartTime: Duration?

    /// Initial position, or `nil` for the default. Negative values become zero.
    public var startTime: Duration? {
        get { storedStartTime }
        set { storedStartTime = newValue?.clampPositiveOrZero }
    }

    private var storedVolume: Double

    /// Volume clamped to `0...100`; NaN uses ``defaultVolume``.
    public var volume: Double {
        get { storedVolume }
        set { storedVolume = Self.normalizedVolume(newValue) }
    }

    private var storedPlaybackRate: Double

    /// Speed multiplier clamped to `0.01...100`. Nonpositive or non-finite values
    /// use ``defaultPlaybackRate``.
    public var playbackRate: Double {
        get { storedPlaybackRate }
        set { storedPlaybackRate = Self.normalizedPlaybackRate(newValue) }
    }

    /// The requested hardware-decoding strategy.
    public var hardwareDecoding: HardwareDecoding

    /// The video backend. Use `.sampleBuffer` for iOS picture in picture.
    public var videoOutput: VideoOutput

    /// Desired HDR behavior for either backend. Presentation status reports
    /// unsupported policies and any backend fallback required to enforce SDR.
    public var hdrPolicy: HDRPolicy

    /// SDR gamut and precision, independent of the HDR policy.
    public var sdrOutput: MPVSDROutputPolicy

    /// Ownership of display conversion and SDR reference viewing behavior.
    public var colorManagement: MPVColorManagement

    /// Renderer cost/quality defaults and optional explicit overrides.
    public var renderingQuality: MPVRenderingQuality

    /// Interlace detection, processing and field-order policy.
    public var deinterlace: MPVDeinterlacePolicy

    /// Strict reproduction eligibility or explicitly lossy Profile 7 compatibility.
    public var dolbyVisionPolicy: MPVDolbyVisionPolicy

    /// How native Dolby Vision conflicts with subtitles and geometry features.
    public var nativeVideoFeaturePolicy: MPVNativeVideoFeaturePolicy

    private var storedSubtitleLuminance: Double

    /// Reference white in nits for native HDR subtitles and overlay graphics.
    /// Values are clamped to `1...1000`; non-finite values use 203 nits.
    public var subtitleLuminance: Double {
        get { storedSubtitleLuminance }
        set { storedSubtitleLuminance = Self.normalizedSubtitleLuminance(newValue) }
    }

    private var storedNetworkCacheSeconds: Duration

    /// Desired network cache duration, clamped to zero or greater.
    public var networkCacheSeconds: Duration {
        get { storedNetworkCacheSeconds }
        set { storedNetworkCacheSeconds = newValue.clampPositiveOrZero }
    }

    private var storedInitialBufferSeconds: Duration

    /// Buffered duration required before initial playback, clamped to zero or greater.
    public var initialBufferSeconds: Duration {
        get { storedInitialBufferSeconds }
        set { storedInitialBufferSeconds = newValue.clampPositiveOrZero }
    }

    /// The minimum severity of forwarded mpv log messages.
    public var logLevel: LogLevel

    /// Extra mpv options applied last. MPVUI's reserved options cannot be overridden.
    ///
    /// For app-owned subtitle fonts, set `sub-fonts-dir` to a local directory path
    /// and `sub-font` to the font's internal family name. MPVUI ships no fonts.
    /// These options affect mpv-rendered subtitles; style text from
    /// ``MPVPlayer/textSubtitleStream()`` in your own UI.
    public var additionalOptions: [String: String]

    /// Creates a configuration using the normalization rules documented on each property.
    public init(
        autoPlay: Bool = true,
        loop: Bool = false,
        startTime: Duration? = nil,
        volume: Double = 100,
        playbackRate: Double = 1,
        hardwareDecoding: HardwareDecoding = .automatic,
        videoOutput: VideoOutput = .metal,
        hdrPolicy: HDRPolicy = .automatic,
        subtitleLuminance: Double = 203,
        sdrOutput: MPVSDROutputPolicy = .automatic,
        colorManagement: MPVColorManagement = .init(),
        renderingQuality: MPVRenderingQuality = .init(),
        deinterlace: MPVDeinterlacePolicy = .init(),
        dolbyVisionPolicy: MPVDolbyVisionPolicy = .strict,
        nativeVideoFeaturePolicy: MPVNativeVideoFeaturePolicy = .preserveDolbyVision,
        networkCacheSeconds: Duration = .seconds(10),
        initialBufferSeconds: Duration = .seconds(1),
        logLevel: LogLevel = .warning,
        additionalOptions: [String: String] = [:]
    ) {
        self.autoPlay = autoPlay
        self.loop = loop
        storedStartTime = startTime?.clampPositiveOrZero
        storedVolume = Self.normalizedVolume(volume)
        storedPlaybackRate = Self.normalizedPlaybackRate(playbackRate)
        self.hardwareDecoding = hardwareDecoding
        self.videoOutput = videoOutput
        self.hdrPolicy = hdrPolicy
        self.sdrOutput = sdrOutput
        self.colorManagement = colorManagement
        self.renderingQuality = renderingQuality
        self.deinterlace = deinterlace
        self.dolbyVisionPolicy = dolbyVisionPolicy
        self.nativeVideoFeaturePolicy = nativeVideoFeaturePolicy
        storedSubtitleLuminance = Self.normalizedSubtitleLuminance(subtitleLuminance)
        storedNetworkCacheSeconds = networkCacheSeconds.clampPositiveOrZero
        storedInitialBufferSeconds = initialBufferSeconds.clampPositiveOrZero
        self.logLevel = logLevel
        self.additionalOptions = additionalOptions
    }

    private static func normalizedVolume(_ value: Double) -> Double {
        guard !value.isNaN else { return defaultVolume }
        return clamp(value, to: 0 ... 100)
    }

    private static func normalizedSubtitleLuminance(_ value: Double) -> Double {
        value.isFinite ? clamp(value, to: 1 ... 1000) : 203
    }

    private static func normalizedPlaybackRate(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return defaultPlaybackRate }
        return clamp(value, to: minimumPlaybackRate ... maximumPlaybackRate)
    }
}
