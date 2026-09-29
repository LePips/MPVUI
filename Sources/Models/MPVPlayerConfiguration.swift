/// Immutable playback defaults and output options for ``MPVPlayer``.
///
/// Runtime controls such as volume and playback rate use the player's methods.
/// Other settings require a new player.
///
/// Pass the configuration to the player initializer on the main actor:
///
/// ```swift
/// let configuration = MPVPlayerConfiguration(
///     autoPlay: false,
///     videoOutput: .sampleBuffer,
///     volume: 75
/// )
/// let player = MPVPlayer(configuration: configuration)
/// ```
public struct MPVPlayerConfiguration: Equatable, Sendable {

    // MARK: - Types

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

        /// Request SDR conversion when supported by the selected backend.
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

    /// The video presentation backend used for the player’s lifetime.
    public enum VideoOutput: String, CaseIterable, Equatable, Sendable {
        /// Full gpu-next rendering through Metal/MoltenVK.
        case metal

        /// Native AVFoundation output with iOS PiP; requires the native-output Libmpv build.
        /// AVFoundation handles color conversion, bypassing gpu-next shaders and tone mapping.
        /// Unsupported native formats report a playback error.
        case sampleBuffer
    }

    // MARK: - Defaults

    /// The default player configuration.
    public static let `default` = Self()

    /// The default initial buffer duration, one second.
    public static let defaultInitialBufferSeconds: Duration = .seconds(1)

    /// The default network cache duration, ten seconds.
    public static let defaultNetworkCacheSeconds: Duration = .seconds(10)

    /// The default playback rate, normal speed.
    public static let defaultPlaybackRate = 1.0

    /// The default playback volume, 100 percent.
    public static let defaultVolume = 100.0

    /// The fastest playback rate accepted by mpv.
    public static let maximumPlaybackRate = 100.0

    /// The slowest playback rate accepted by mpv.
    public static let minimumPlaybackRate = 0.01

    // MARK: - Boolean options

    /// Whether loading a source should begin playback automatically.
    public let autoPlay: Bool

    /// Whether playback should restart after reaching the end of the media.
    public let loop: Bool

    // MARK: - Numeric options

    /// Speed multiplier clamped to `0.01...100`. Nonpositive or non-finite values
    /// use ``defaultPlaybackRate``.
    public let playbackRate: Double

    /// Reference white in nits for native HDR subtitles and overlay graphics.
    /// Values are clamped to `1...1000`; non-finite values use 203 nits.
    public let subtitleLuminance: Double

    /// Volume clamped to `0...100`; NaN uses ``defaultVolume``.
    public let volume: Double

    // MARK: - Timing options

    /// Buffered duration required before initial playback, clamped to zero or greater.
    public let initialBufferSeconds: Duration

    /// Desired network cache duration, clamped to zero or greater.
    public let networkCacheSeconds: Duration

    /// Initial position, or `nil` for the default. Negative values become zero.
    public let startTime: Duration?

    // MARK: - Policies

    /// Audio decoding, spatialization, and session settings applied when creating the player.
    /// ``additionalOptions`` can override these defaults.
    public let audio: MPVAudioConfiguration

    /// Ownership of display conversion and SDR reference viewing behavior.
    /// - Note: Overrides have no effect with sample-buffer output; AVFoundation owns conversion.
    public let colorManagement: MPVColorManagement

    /// Interlace detection, processing and field-order policy.
    public let deinterlace: MPVDeinterlacePolicy

    /// Strict reproduction eligibility or explicitly lossy Profile 7 compatibility.
    public let dolbyVisionPolicy: MPVDolbyVisionPolicy

    /// The requested hardware-decoding strategy.
    public let hardwareDecoding: HardwareDecoding

    /// Desired HDR behavior for the selected backend.
    /// - Note: Sample-buffer overrides require OS 26; earlier systems use automatic HDR.
    public let hdrPolicy: HDRPolicy

    /// The minimum severity of forwarded mpv log messages.
    public let logLevel: LogLevel

    /// Renderer cost/quality defaults and optional explicit overrides.
    /// - Note: Has no effect with sample-buffer output.
    public let renderingQuality: MPVRenderingQuality

    /// SDR gamut and precision, independent of the HDR policy.
    /// - Note: Has no effect with sample-buffer output; AVFoundation manages precision.
    public let sdrOutput: MPVSDROutputPolicy

    /// The video backend used for the player's lifetime. Defaults to sample buffers.
    /// Other options never change the selected backend.
    public let videoOutput: VideoOutput

    // MARK: - Additional options

    /// Extra mpv options applied last. MPVUI's reserved options cannot be overridden.
    /// - Note: gpu-next picture controls (`brightness`, `contrast`, `gamma`, `hue`,
    ///   `saturation`) have no effect with sample-buffer output.
    ///
    /// For app-owned subtitle fonts, set `sub-fonts-dir` to a local directory path
    /// and `sub-font` to the font's internal family name. MPVUI ships no fonts.
    /// These options affect mpv-rendered subtitles; style text from
    /// ``MPVPlayer/textSubtitleStream()`` in your own UI.
    public let additionalOptions: [String: String]

    // MARK: - Initialization

    /// Creates a configuration using the normalization rules documented on each property.
    /// `videoOutput` defaults to sample buffers. Unsupported renderer settings have no effect.
    public init(
        additionalOptions: [String: String] = [:],
        audio: MPVAudioConfiguration = .init(),
        autoPlay: Bool = true,
        colorManagement: MPVColorManagement = .init(),
        deinterlace: MPVDeinterlacePolicy = .init(),
        dolbyVisionPolicy: MPVDolbyVisionPolicy = .strict,
        hardwareDecoding: HardwareDecoding = .automatic,
        hdrPolicy: HDRPolicy = .automatic,
        initialBufferSeconds: Duration = .seconds(1),
        logLevel: LogLevel = .warning,
        loop: Bool = false,
        networkCacheSeconds: Duration = .seconds(10),
        playbackRate: Double = 1,
        renderingQuality: MPVRenderingQuality = .init(),
        sdrOutput: MPVSDROutputPolicy = .automatic,
        startTime: Duration? = nil,
        subtitleLuminance: Double = 203,
        videoOutput: VideoOutput = .sampleBuffer,
        volume: Double = 100
    ) {
        self.additionalOptions = additionalOptions
        self.audio = audio
        self.autoPlay = autoPlay
        self.colorManagement = colorManagement
        self.deinterlace = deinterlace
        self.dolbyVisionPolicy = dolbyVisionPolicy
        self.hardwareDecoding = hardwareDecoding
        self.hdrPolicy = hdrPolicy
        self.initialBufferSeconds = initialBufferSeconds.clampPositiveOrZero
        self.logLevel = logLevel
        self.loop = loop
        self.networkCacheSeconds = networkCacheSeconds.clampPositiveOrZero
        self.playbackRate = Self.normalizedPlaybackRate(playbackRate)
        self.renderingQuality = renderingQuality
        self.sdrOutput = sdrOutput
        self.startTime = startTime?.clampPositiveOrZero
        self.subtitleLuminance = Self.normalizedSubtitleLuminance(subtitleLuminance)
        self.videoOutput = videoOutput
        self.volume = Self.normalizedVolume(volume)
    }

    // MARK: - Normalization

    private static func normalizedPlaybackRate(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return defaultPlaybackRate }
        return clamp(value, to: minimumPlaybackRate ... maximumPlaybackRate)
    }

    private static func normalizedSubtitleLuminance(_ value: Double) -> Double {
        value.isFinite ? clamp(value, to: 1 ... 1000) : 203
    }

    private static func normalizedVolume(_ value: Double) -> Double {
        guard !value.isNaN else { return defaultVolume }
        return clamp(value, to: 0 ... 100)
    }
}
