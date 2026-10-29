import MPVCore

/// Immutable playback defaults and output options for ``MPVPlayer``.
///
/// Use the player's methods to change runtime controls such as volume and playback rate.
/// Other settings require a new player.
///
/// Pass the configuration to the player initializer on the main actor:
///
/// ```swift
/// let configuration = MPVPlayerConfiguration(
///     automaticallyPlays: false,
///     videoOutput: .sampleBuffer,
///     volume: 75
/// )
/// let player = MPVPlayer(configuration: configuration)
/// ```
public struct MPVPlayerConfiguration: Equatable, Sendable {

    // MARK: - Types

    /// The hardware-decoding strategy requested from mpv.
    public enum HardwareDecoding: String, CaseIterable, Equatable, Sendable {

        /// Selects a safe hardware decoder, preferring VideoToolbox for Metal output.
        case automatic = "auto-safe"

        /// Requests Apple's VideoToolbox decoder.
        case videoToolbox = "videotoolbox"

        /// Decodes video in software.
        case disabled = "no"

        package var coreValue: MPVHardwareDecoding {
            switch self {
            case .automatic: .automatic
            case .videoToolbox: .videoToolbox
            case .disabled: .disabled
            }
        }
    }

    /// How MPVUI configures HDR output and tone mapping.
    public typealias HDRPolicy = MPVHDRPolicy

    /// The minimum severity of forwarded log messages. Each level includes more severe messages.
    public typealias LogLevel = MPVLogLevel

    /// The video presentation backend used for the player's lifetime.
    public enum VideoOutput: String, CaseIterable, Equatable, Sendable {

        /// Full `gpu-next` rendering through Metal and MoltenVK.
        case metal

        /// Native AVFoundation output with iOS picture in picture. Requires the native-output Libmpv build.
        /// AVFoundation handles color conversion, bypassing `gpu-next` shaders and tone mapping.
        /// Unsupported native formats report a playback error.
        case sampleBuffer

        package var coreValue: MPVVideoOutput {
            switch self {
            case .metal: .metal
            case .sampleBuffer: .sampleBuffer
            }
        }
    }

    /// Whether the player requests platform display matching.
    public typealias DisplayMatching = MPVDisplayMatching

    // MARK: - Defaults

    /// The default player configuration.
    public static let `default` = Self()

    /// The default initial buffer duration, one second.
    public static let defaultInitialBufferDuration: Duration = .seconds(1)

    /// The default network cache duration, ten seconds.
    public static let defaultNetworkCacheDuration: Duration = .seconds(10)

    /// The default playback rate, normal speed.
    public static let defaultPlaybackRate = 1.0

    /// The default playback volume, 100 percent.
    public static let defaultVolume = 100.0

    /// The fastest playback rate accepted by mpv.
    public static let maximumPlaybackRate = 100.0

    /// The slowest playback rate accepted by mpv.
    public static let minimumPlaybackRate = 0.01

    // MARK: - Boolean options

    /// Whether loading a source begins playback automatically.
    public let automaticallyPlays: Bool

    /// Whether playback restarts after reaching the end of the media.
    public let isLoopingEnabled: Bool

    // MARK: - Numeric options

    /// The initial playback-rate multiplier, clamped to `0.01...100`.
    /// Nonpositive or non-finite values use ``defaultPlaybackRate``.
    public let playbackRate: Double

    /// Reference white in nits for native HDR subtitles and overlay graphics.
    /// Values are clamped to `1...1000`. Non-finite values use 203 nits.
    public let subtitleLuminance: Double

    /// The initial playback volume, clamped to `0...100`. NaN uses ``defaultVolume``.
    public let volume: Double

    // MARK: - Timing options

    /// Buffered duration required before initial playback, clamped to zero or greater.
    public let initialBufferDuration: Duration

    /// Desired network cache duration, clamped to zero or greater.
    public let networkCacheDuration: Duration

    /// Initial position, or `nil` for the default. Negative values become zero.
    public let startTime: Duration?

    // MARK: - Policies

    /// Audio decoding, spatialization, and session settings applied when creating the player.
    /// ``additionalOptions`` can override these defaults.
    public let audio: MPVAudioConfiguration

    /// Demuxer cache policy and packet memory limits.
    public let cache: MPVCacheConfiguration

    /// Display matching policy. Automatic supplies criteria on tvOS.
    public let displayMatching: DisplayMatching

    /// Ownership of display conversion and SDR reference viewing behavior.
    /// - Note: Overrides have no effect with sample-buffer output. AVFoundation owns conversion.
    public let colorManagement: MPVColorManagement

    /// Interlace detection, processing, and field-order policy.
    public let deinterlace: MPVDeinterlacePolicy

    /// The policy for native Dolby Vision playback and lossy Profile 7 conversion.
    public let dolbyVisionPolicy: MPVDolbyVisionPolicy

    /// The requested hardware-decoding strategy.
    public let hardwareDecoding: HardwareDecoding

    /// Desired HDR behavior for the selected backend.
    /// - Note: Sample-buffer overrides require OS 26. Earlier systems use automatic HDR.
    public let hdrPolicy: HDRPolicy

    /// The minimum severity of forwarded mpv log messages.
    public let logLevel: LogLevel

    /// Rendering quality presets and optional overrides.
    /// - Note: Has no effect with sample-buffer output.
    public let renderingQuality: MPVRenderingQuality

    /// SDR gamut and precision, independent of the HDR policy.
    /// - Note: Has no effect with sample-buffer output. AVFoundation manages precision.
    public let sdrOutput: MPVSDROutputPolicy

    /// The video backend used for the player's lifetime. Defaults to sample buffers.
    /// Other options never change the selected backend.
    public let videoOutput: VideoOutput

    // MARK: - Additional options

    /// Extra mpv options applied last. These cannot override MPVUI's reserved options.
    /// - Note: `gpu-next` picture controls (`brightness`, `contrast`, `gamma`, `hue`,
    ///   `saturation`) have no effect with sample-buffer output.
    ///
    /// For app-owned subtitle fonts, set `sub-fonts-dir` to a local directory path
    /// and `sub-font` to the font's internal family name. MPVUI ships no fonts.
    /// These options affect mpv-rendered subtitles. Style text from
    /// ``MPVPlayer/makeTextSubtitleStream()`` in your own UI.
    public let additionalOptions: [String: String]

    // MARK: - Normalization

    /// Resolves the shared playback settings without carrying Apple display objects.
    package var sessionConfiguration: MPVSessionConfiguration {
        MPVSessionConfiguration(
            additionalOptions: additionalOptions,
            audio: audio,
            automaticallyPlays: automaticallyPlays,
            cache: cache,
            deinterlace: deinterlace,
            dolbyVisionPolicy: dolbyVisionPolicy,
            hardwareDecoding: hardwareDecoding.coreValue,
            hdrPolicy: hdrPolicy,
            initialBufferDuration: initialBufferDuration,
            logLevel: logLevel,
            isLoopingEnabled: isLoopingEnabled,
            networkCacheDuration: networkCacheDuration,
            playbackRate: playbackRate,
            renderingQuality: renderingQuality,
            startTime: startTime,
            subtitleLuminance: subtitleLuminance,
            videoOutput: videoOutput.coreValue,
            volume: volume
        )
    }

    // MARK: - Initialization

    /// Creates a configuration using the normalization rules documented on each property.
    /// `videoOutput` defaults to sample buffers. Unsupported renderer settings have no effect.
    public init(
        additionalOptions: [String: String] = [:],
        audio: MPVAudioConfiguration = .init(),
        automaticallyPlays: Bool = true,
        cache: MPVCacheConfiguration = .init(),
        colorManagement: MPVColorManagement = .init(),
        deinterlace: MPVDeinterlacePolicy = .init(),
        displayMatching: DisplayMatching = .automatic,
        dolbyVisionPolicy: MPVDolbyVisionPolicy = .strict,
        hardwareDecoding: HardwareDecoding = .automatic,
        hdrPolicy: HDRPolicy = .automatic,
        initialBufferDuration: Duration = defaultInitialBufferDuration,
        logLevel: LogLevel = .warning,
        isLoopingEnabled: Bool = false,
        networkCacheDuration: Duration = defaultNetworkCacheDuration,
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
        self.automaticallyPlays = automaticallyPlays
        self.cache = cache
        self.displayMatching = displayMatching
        self.colorManagement = colorManagement
        self.deinterlace = deinterlace
        self.dolbyVisionPolicy = dolbyVisionPolicy
        self.hardwareDecoding = hardwareDecoding
        self.hdrPolicy = hdrPolicy
        self.initialBufferDuration = initialBufferDuration.clampPositiveOrZero
        self.logLevel = logLevel
        self.isLoopingEnabled = isLoopingEnabled
        self.networkCacheDuration = networkCacheDuration.clampPositiveOrZero
        self.playbackRate = MPVSessionConfiguration.normalizedPlaybackRate(playbackRate)
        self.renderingQuality = renderingQuality
        self.sdrOutput = sdrOutput
        self.startTime = startTime?.clampPositiveOrZero
        self.subtitleLuminance = MPVSessionConfiguration.normalizedSubtitleLuminance(subtitleLuminance)
        self.videoOutput = videoOutput
        self.volume = MPVSessionConfiguration.normalizedVolume(volume)
    }
}
