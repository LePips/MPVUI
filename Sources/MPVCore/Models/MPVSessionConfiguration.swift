/// Immutable playback defaults and output options for ``MPVSession``.
///
/// Use session commands to change runtime controls such as volume and playback rate.
/// Other settings require a new session. Platform adapters resolve output capabilities.
public struct MPVSessionConfiguration: Equatable, Sendable {

    // MARK: - Types

    /// The hardware-decoding strategy requested from mpv.
    public typealias HardwareDecoding = MPVHardwareDecoding
    /// How the session configures HDR output and tone mapping.
    public typealias HDRPolicy = MPVHDRPolicy
    /// The minimum severity of forwarded mpv log messages.
    public typealias LogLevel = MPVLogLevel
    /// The video presentation backend requested from the platform adapter.
    public typealias VideoOutput = MPVVideoOutput

    // MARK: - Defaults

    /// The default session configuration.
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
    /// The reference white in nits for native HDR subtitles and overlay graphics.
    /// Values are clamped to `1...1000`. Non-finite values use 203 nits.
    public let subtitleLuminance: Double
    /// The initial playback volume, clamped to `0...100`. NaN uses ``defaultVolume``.
    public let volume: Double

    // MARK: - Timing options

    /// The buffered duration required before initial playback, clamped to zero or greater.
    public let initialBufferDuration: Duration
    /// The desired network cache duration, clamped to zero or greater.
    public let networkCacheDuration: Duration
    /// The initial playback position, or `nil` for the default. Negative values become zero.
    public let startTime: Duration?

    // MARK: - Policies

    /// Audio decoding, spatialization, and session settings applied when creating the session.
    /// ``additionalOptions`` can override these defaults.
    public let audio: MPVAudioConfiguration
    /// The demuxer cache policy and packet memory limits.
    public let cache: MPVCacheConfiguration
    /// The interlace detection, processing, and field-order policy.
    public let deinterlace: MPVDeinterlacePolicy
    /// The policy for native Dolby Vision playback and lossy Profile 7 conversion.
    public let dolbyVisionPolicy: MPVDolbyVisionPolicy
    /// The requested hardware-decoding strategy.
    public let hardwareDecoding: HardwareDecoding
    /// The desired HDR behavior for the selected video output.
    public let hdrPolicy: HDRPolicy
    /// The minimum severity of forwarded mpv log messages.
    public let logLevel: LogLevel
    /// Rendering quality presets and optional overrides.
    /// Native video outputs ignore GPU rendering options.
    public let renderingQuality: MPVRenderingQuality
    /// The video presentation backend requested from the platform adapter.
    public let videoOutput: VideoOutput
    /// Whether automatic Android output may switch to GPU output for subtitle composition.
    /// Explicit video output selections do not use this policy.
    public let nativeVideoFeaturePolicy: MPVNativeVideoFeaturePolicy

    // MARK: - Additional options

    /// Extra mpv options applied last. These cannot override options managed by the session.
    public let additionalOptions: [String: String]

    // MARK: - Initialization

    /// Creates a configuration using the normalization rules documented on each property.
    public init(
        additionalOptions: [String: String] = [:],
        audio: MPVAudioConfiguration = .init(),
        automaticallyPlays: Bool = true,
        cache: MPVCacheConfiguration = .init(),
        deinterlace: MPVDeinterlacePolicy = .init(),
        dolbyVisionPolicy: MPVDolbyVisionPolicy = .strict,
        hardwareDecoding: HardwareDecoding = .automatic,
        hdrPolicy: HDRPolicy = .automatic,
        initialBufferDuration: Duration = defaultInitialBufferDuration,
        logLevel: LogLevel = .warning,
        isLoopingEnabled: Bool = false,
        networkCacheDuration: Duration = defaultNetworkCacheDuration,
        nativeVideoFeaturePolicy: MPVNativeVideoFeaturePolicy = .preserveDolbyVision,
        playbackRate: Double = 1,
        renderingQuality: MPVRenderingQuality = .init(),
        startTime: Duration? = nil,
        subtitleLuminance: Double = 203,
        videoOutput: VideoOutput = .sampleBuffer,
        volume: Double = 100
    ) {
        self.additionalOptions = additionalOptions
        self.audio = audio
        self.automaticallyPlays = automaticallyPlays
        self.cache = cache
        self.deinterlace = deinterlace
        self.dolbyVisionPolicy = dolbyVisionPolicy
        self.hardwareDecoding = hardwareDecoding
        self.hdrPolicy = hdrPolicy
        self.initialBufferDuration = initialBufferDuration.clampPositiveOrZero
        self.logLevel = logLevel
        self.isLoopingEnabled = isLoopingEnabled
        self.networkCacheDuration = networkCacheDuration.clampPositiveOrZero
        self.nativeVideoFeaturePolicy = nativeVideoFeaturePolicy
        self.playbackRate = Self.normalizedPlaybackRate(playbackRate)
        self.renderingQuality = renderingQuality
        self.startTime = startTime?.clampPositiveOrZero
        self.subtitleLuminance = Self.normalizedSubtitleLuminance(subtitleLuminance)
        self.videoOutput = videoOutput
        self.volume = Self.normalizedVolume(volume)
    }

    // MARK: - Normalization

    package static func normalizedPlaybackRate(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return defaultPlaybackRate }

        return clamped(value, to: minimumPlaybackRate ... maximumPlaybackRate)
    }

    package static func normalizedSubtitleLuminance(_ value: Double) -> Double {
        value.isFinite ? clamped(value, to: 1 ... 1000) : 203
    }

    package static func normalizedVolume(_ value: Double) -> Double {
        guard !value.isNaN else { return defaultVolume }

        return clamped(value, to: 0 ... 100)
    }
}
