/// Options applied when creating and controlling an mpv player.
public struct MPVPlayerConfiguration: Equatable, Sendable {
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
    }

    /// The minimum severity of messages forwarded from mpv.
    public enum LogLevel: String, CaseIterable, Equatable, Sendable {
        /// Disable mpv log forwarding.
        case none = "no"

        /// Forward only fatal failures.
        case fatal

        /// Forward errors and fatal failures.
        case error

        /// Forward warnings and more severe messages.
        case warning = "warn"

        /// Forward informational messages and more severe messages.
        case info

        /// Forward status messages and more severe messages.
        case status

        /// Forward verbose diagnostic messages.
        case verbose = "v"

        /// Forward debug diagnostic messages.
        case debug

        /// Forward all trace messages.
        case trace
    }

    /// The default playback volume.
    public static let defaultVolume = 100.0

    /// The default playback-rate multiplier.
    public static let defaultPlaybackRate = 1.0

    /// The slowest playback rate accepted by mpv.
    public static let minimumPlaybackRate = 0.01

    /// The fastest playback rate accepted by mpv.
    public static let maximumPlaybackRate = 100.0

    /// The default desired network cache duration.
    public static let defaultNetworkCacheSeconds: Duration = .seconds(10)

    /// The default amount of media buffered before initial playback.
    public static let defaultInitialBufferSeconds: Duration = .seconds(1)

    /// A configuration containing all documented MPVUI defaults.
    public static let `default` = Self()

    /// Whether loading a source should begin playback automatically.
    public var autoPlay: Bool

    /// Whether playback should restart after reaching the end of the media.
    public var loop: Bool

    private var storedStartTime: Duration?

    /// The initial timeline position, or `nil` to start normally.
    ///
    /// Negative values are clamped to zero.
    public var startTime: Duration? {
        get { storedStartTime }
        set { storedStartTime = Self.normalizedStartTime(newValue) }
    }

    private var storedVolume: Double

    /// Playback volume, clamped to the inclusive range `0...100`.
    public var volume: Double {
        get { storedVolume }
        set { storedVolume = Self.normalizedVolume(newValue) }
    }

    private var storedPlaybackRate: Double

    /// Playback speed, clamped to mpv's `0.01...100` multiplier range.
    ///
    /// Zero, negative, and non-finite values reset the rate to
    /// ``defaultPlaybackRate``.
    public var playbackRate: Double {
        get { storedPlaybackRate }
        set { storedPlaybackRate = Self.normalizedPlaybackRate(newValue) }
    }

    /// The requested hardware-decoding strategy.
    public var hardwareDecoding: HardwareDecoding

    /// The requested HDR presentation policy.
    public var hdrPolicy: HDRPolicy

    private var storedNetworkCacheSeconds: Duration

    /// Desired network cache duration.
    ///
    /// Negative values are clamped to zero.
    public var networkCacheSeconds: Duration {
        get { storedNetworkCacheSeconds }
        set { storedNetworkCacheSeconds = Self.normalizedNetworkCacheSeconds(newValue) }
    }

    private var storedInitialBufferSeconds: Duration

    /// Desired buffered duration before initial playback begins.
    ///
    /// Negative values are clamped to zero.
    public var initialBufferSeconds: Duration {
        get { storedInitialBufferSeconds }
        set { storedInitialBufferSeconds = Self.normalizedInitialBufferSeconds(newValue) }
    }

    /// The minimum severity of forwarded mpv log messages.
    public var logLevel: LogLevel

    /// Additional mpv options applied after MPVUI's options.
    ///
    /// Some options are reserved by MPVUI and cannot be overridden.
    public var additionalOptions: [String: String]

    /// Creates a player configuration.
    ///
    /// - Parameters:
    ///   - autoPlay: Whether a newly loaded source should begin playing.
    ///   - loop: Whether playback should restart after reaching the end.
    ///   - startTime: Optional initial timeline position.
    ///   - volume: Playback volume, clamped to `0...100`.
    ///   - playbackRate: Positive playback-speed multiplier; invalid values use `1`.
    ///   - hardwareDecoding: Requested hardware-decoding strategy.
    ///   - hdrPolicy: Requested HDR presentation policy.
    ///   - networkCacheSeconds: Desired network cache duration.
    ///   - initialBufferSeconds: Buffered duration required before initial playback.
    ///   - logLevel: Minimum severity of forwarded mpv log messages.
    ///   - additionalOptions: Advanced mpv options applied last.
    public init(
        autoPlay: Bool = true,
        loop: Bool = false,
        startTime: Duration? = nil,
        volume: Double = 100,
        playbackRate: Double = 1,
        hardwareDecoding: HardwareDecoding = .automatic,
        hdrPolicy: HDRPolicy = .automatic,
        networkCacheSeconds: Duration = .seconds(10),
        initialBufferSeconds: Duration = .seconds(1),
        logLevel: LogLevel = .warning,
        additionalOptions: [String: String] = [:]
    ) {
        self.autoPlay = autoPlay
        self.loop = loop
        storedStartTime = Self.normalizedStartTime(startTime)
        storedVolume = Self.normalizedVolume(volume)
        storedPlaybackRate = Self.normalizedPlaybackRate(playbackRate)
        self.hardwareDecoding = hardwareDecoding
        self.hdrPolicy = hdrPolicy
        storedNetworkCacheSeconds = Self.normalizedNetworkCacheSeconds(networkCacheSeconds)
        storedInitialBufferSeconds = Self.normalizedInitialBufferSeconds(initialBufferSeconds)
        self.logLevel = logLevel
        self.additionalOptions = additionalOptions
    }

    private static func normalizedStartTime(_ value: Duration?) -> Duration? {
        value.map { max(.zero, $0) }
    }

    private static func normalizedVolume(_ value: Double) -> Double {
        guard !value.isNaN else { return defaultVolume }
        return clamp(value, to: 0 ... 100)
    }

    private static func normalizedPlaybackRate(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return defaultPlaybackRate }
        return clamp(value, to: minimumPlaybackRate ... maximumPlaybackRate)
    }

    private static func normalizedNetworkCacheSeconds(_ value: Duration) -> Duration {
        max(.zero, value)
    }

    private static func normalizedInitialBufferSeconds(_ value: Duration) -> Duration {
        max(.zero, value)
    }
}
