/// Portable playback defaults after platform capability resolution.
public struct MPVSessionConfiguration: Equatable, Sendable {

    // MARK: - Types

    /// Shared playback setting.
    public typealias HardwareDecoding = MPVHardwareDecoding
    /// Shared playback setting.
    public typealias HDRPolicy = MPVHDRPolicy
    /// Shared playback setting.
    public typealias LogLevel = MPVLogLevel
    /// Shared playback setting.
    public typealias VideoOutput = MPVVideoOutput

    // MARK: - Defaults

    /// Shared playback setting.
    public static let `default` = Self()
    /// Shared playback setting.
    public static let defaultInitialBufferSeconds: Duration = .seconds(1)
    /// Shared playback setting.
    public static let defaultNetworkCacheSeconds: Duration = .seconds(10)
    /// Shared playback setting.
    public static let defaultPlaybackRate = 1.0
    /// Shared playback setting.
    public static let defaultVolume = 100.0
    /// Shared playback setting.
    public static let maximumPlaybackRate = 100.0
    /// Shared playback setting.
    public static let minimumPlaybackRate = 0.01

    // MARK: - Boolean options

    /// Whether a new load starts playing.
    public let autoPlay: Bool
    /// Whether playback repeats at the end of the source.
    public let loop: Bool

    // MARK: - Numeric options

    /// Initial speed, normalized to 0.01 through 100.
    public let playbackRate: Double
    /// Reference white for native subtitles in nits.
    public let subtitleLuminance: Double
    /// Initial volume, normalized to 0 through 100.
    public let volume: Double

    // MARK: - Timing options

    /// Required initial buffer duration.
    public let initialBufferSeconds: Duration
    /// Desired network cache duration.
    public let networkCacheSeconds: Duration
    /// Initial playback position.
    public let startTime: Duration?

    // MARK: - Policies

    /// Audio decoding and spatialization policy.
    public let audio: MPVAudioConfiguration
    /// Demuxer packet cache policy.
    public let cache: MPVCacheConfiguration
    /// Video deinterlacing policy.
    public let deinterlace: MPVDeinterlacePolicy
    /// Explicit permission for Dolby Vision conversion.
    public let dolbyVisionPolicy: MPVDolbyVisionPolicy
    /// Requested decoder strategy.
    public let hardwareDecoding: HardwareDecoding
    /// Requested dynamic range policy.
    public let hdrPolicy: HDRPolicy
    /// Minimum forwarded diagnostic severity.
    public let logLevel: LogLevel
    /// Renderer quality and filter settings.
    public let renderingQuality: MPVRenderingQuality
    /// Backend resolved by the platform adapter.
    public let videoOutput: VideoOutput
    /// Subtitle-driven fallback for automatic Android output only.
    public let nativeVideoFeaturePolicy: MPVNativeVideoFeaturePolicy

    // MARK: - Additional options

    /// Caller options, subject to session ownership validation.
    public let additionalOptions: [String: String]

    // MARK: - Initialization

    /// Creates normalized playback settings for a platform-resolved session.
    public init(
        additionalOptions: [String: String] = [:],
        audio: MPVAudioConfiguration = .init(),
        autoPlay: Bool = true,
        cache: MPVCacheConfiguration = .init(),
        deinterlace: MPVDeinterlacePolicy = .init(),
        dolbyVisionPolicy: MPVDolbyVisionPolicy = .strict,
        hardwareDecoding: HardwareDecoding = .automatic,
        hdrPolicy: HDRPolicy = .automatic,
        initialBufferSeconds: Duration = defaultInitialBufferSeconds,
        logLevel: LogLevel = .warning,
        loop: Bool = false,
        networkCacheSeconds: Duration = defaultNetworkCacheSeconds,
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
        self.autoPlay = autoPlay
        self.cache = cache
        self.deinterlace = deinterlace
        self.dolbyVisionPolicy = dolbyVisionPolicy
        self.hardwareDecoding = hardwareDecoding
        self.hdrPolicy = hdrPolicy
        self.initialBufferSeconds = initialBufferSeconds.clampPositiveOrZero
        self.logLevel = logLevel
        self.loop = loop
        self.networkCacheSeconds = networkCacheSeconds.clampPositiveOrZero
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
        return clamp(value, to: minimumPlaybackRate ... maximumPlaybackRate)
    }

    package static func normalizedSubtitleLuminance(_ value: Double) -> Double {
        value.isFinite ? clamp(value, to: 1 ... 1000) : 203
    }

    package static func normalizedVolume(_ value: Double) -> Double {
        guard !value.isNaN else { return defaultVolume }
        return clamp(value, to: 0 ... 100)
    }
}
